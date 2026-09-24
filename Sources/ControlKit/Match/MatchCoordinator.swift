import Foundation

/// Runs the three matching tiers in order and turns the outcome into a decision
/// the UI can act on: cache → local rules → Jev. An open-ended question, when
/// drafting is set up, stops after the local rules and is drafted instead.
///
/// Every exit path is safe by construction — a network failure, a low-confidence
/// answer, and an unrecognised field all land on the picker, never on a wrong
/// insert.
@MainActor
public final class MatchCoordinator {
    private let vault: VaultStore
    private let cache: MatchCache
    private let preferences: Preferences
    private let local = LocalMatcher()

    public init(vault: VaultStore, cache: MatchCache, preferences: Preferences) {
        self.vault = vault
        self.cache = cache
        self.preferences = preferences
    }

    public func decide(for context: FieldContext) async -> FillDecision {
        if context.isSecureField { return .blocked(.secureField) }
        if preferences.isDenied(context) { return .blocked(.deniedApp) }

        let fillable = vault.matchableFields
        guard !fillable.isEmpty else { return .blocked(.emptyVault) }
        let fillableKeys = Set(fillable.map(\.key))

        let localRanking = local.match(context, fillable: fillableKeys, hints: vault.matchHints)

        // Tier 0 — cache. Instant, offline, and holds the user's own corrections.
        // The local ranking still runs, cheaply and offline, so a remembered
        // answer that turns out to be wrong has somewhere to cycle to.
        if let entry = cache.entry(for: context), fillableKeys.contains(entry.key) {
            let result = MatchResult(
                key: entry.key,
                confidence: 1.0,
                source: .cache,
                alternatives: localRanking.filter { $0.key != entry.key },
                looksSensitive: LocalMatcher.looksSensitive(context)
            )
            return gate(result, context: context)
        }

        // Tier 1 — deterministic rules.
        if let best = localRanking.first, best.score >= MatchThresholds.autoInsert {
            let result = MatchResult(
                key: best.key,
                confidence: best.score,
                source: .local,
                alternatives: Array(localRanking.dropFirst()),
                looksSensitive: LocalMatcher.looksSensitive(context)
            )
            return gate(result, context: context)
        }

        // An open-ended question wants writing, not a saved detail. It goes
        // after the cache and the rules, so a snippet the user once picked for
        // this field, or a confident rule, still wins — and before Jev, whose
        // answer would only be thrown away.
        if preferences.canDraftAnswers, LongAnswerPolicy.isOpenEndedQuestion(context) {
            return .draft
        }

        // Tier 2 — Jev, for everything the rules could not settle.
        if preferences.jevEnabled, !preferences.jevAPIKey.isEmpty, !context.hasNoDescriptiveText {
            let candidates = JevMatcher.candidates(
                from: fillable,
                localRanking: localRanking,
                context: context
            )
            let matcher = JevMatcher(client: JevClient(apiKey: preferences.jevAPIKey))
            do {
                if let result = try await matcher.match(context: context, candidates: candidates) {
                    if result.confidence >= MatchThresholds.confirm {
                        return gate(result, context: context)
                    }
                    return .choose(ranked: merged(result, localRanking, fillable), hint: nil)
                }
            } catch {
                // Fall through to whatever the local tier managed. A Jev outage
                // degrades the experience; it must not break filling.
                Log.match.error("Jev lookup failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Fallbacks.
        if let best = localRanking.first, best.score >= MatchThresholds.confirm {
            let result = MatchResult(
                key: best.key,
                confidence: best.score,
                source: .local,
                alternatives: Array(localRanking.dropFirst()),
                looksSensitive: LocalMatcher.looksSensitive(context)
            )
            return .confirm(result)
        }

        let hint = context.hasNoDescriptiveText ? BlockReason.unreadableField.message : nil
        return .choose(ranked: allRanked(localRanking, fillable), hint: hint)
    }

    // MARK: Gating

    /// Applies the confidence thresholds plus the two hard overrides: anything
    /// sensitive is always confirmed, and so is anything in a category the user
    /// has marked confirm-only.
    private func gate(_ result: MatchResult, context: FieldContext) -> FillDecision {
        let field = vault.field(for: result.key)
        let categoryRequiresConfirm = field.map { preferences.confirmedCategories.contains($0.category) } ?? false
        let sensitive = result.looksSensitive || (field?.sensitive ?? false)

        if sensitive || categoryRequiresConfirm || !preferences.autoInsertEnabled {
            return .confirm(result)
        }
        return result.confidence >= MatchThresholds.autoInsert ? .insert(result) : .confirm(result)
    }

    // MARK: Ranking helpers

    /// Jev's ranking first, then anything else the local tier liked, then the rest.
    private func merged(
        _ result: MatchResult,
        _ localRanking: [ScoredKey],
        _ fillable: [VaultField]
    ) -> [ScoredKey] {
        var ordered = [ScoredKey(key: result.key, score: result.confidence)] + result.alternatives
        var seen = Set(ordered.map(\.key))
        for scored in localRanking where seen.insert(scored.key).inserted {
            ordered.append(scored)
        }
        for field in fillable where seen.insert(field.key).inserted {
            ordered.append(ScoredKey(key: field.key, score: 0))
        }
        return ordered
    }

    private func allRanked(_ localRanking: [ScoredKey], _ fillable: [VaultField]) -> [ScoredKey] {
        var ordered = localRanking
        var seen = Set(ordered.map(\.key))
        for field in fillable where seen.insert(field.key).inserted {
            ordered.append(ScoredKey(key: field.key, score: 0))
        }
        return ordered
    }

    // MARK: Learning

    public func remember(_ key: String, for context: FieldContext, source: MatchSource, userConfirmed: Bool) {
        cache.record(key, for: context, source: source, userConfirmed: userConfirmed)
    }
}
