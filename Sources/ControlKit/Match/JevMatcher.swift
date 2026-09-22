import Foundation

/// Turns a field into a Jev question, and Jev's answer back into a `MatchResult`.
///
/// **This type is the privacy boundary.** What crosses it: the field's label,
/// placeholder, role, the app name, the page domain, nearby static text, and the
/// *names and descriptions* of candidate vault keys. What never crosses it: any
/// stored value. Jev answers with a key; the value is looked up locally afterward.
public struct JevMatcher: Sendable {
    /// Jev is told about at most this many keys. A focused list beats an
    /// exhaustive one — atomic, well-scoped questions are what the model is for,
    /// and a 40-option choice is neither.
    public static let maxCandidates = 12
    /// Ambient page text is useful context and also the easiest way to blow the
    /// 32 KiB cap, so it is capped hard on both count and length.
    public static let maxNearbyText = 8
    public static let maxNearbyTextLength = 120

    /// The option Jev picks when nothing in the vault fits. Without an explicit
    /// escape hatch the model is forced to choose something.
    public static let noMatchKey = "no_match"

    private static let fieldQuestion = "field"
    private static let sensitiveQuestion = "is_sensitive"

    public let client: JevClient

    public init(client: JevClient) {
        self.client = client
    }

    // MARK: Request construction

    public static func state(for context: FieldContext) -> [String: JSONValue] {
        var state: [String: JSONValue] = [
            "app": .string(context.appName),
            "field_is_empty": .bool(context.isEmpty),
        ]
        if let domain = context.domain { state["page_domain"] = .string(domain) }
        if let role = context.role { state["field_role"] = .string(role) }
        if let label = context.label { state["field_label"] = .string(label) }
        if let placeholder = context.placeholder { state["field_placeholder"] = .string(placeholder) }
        if let help = context.helpText { state["field_help_text"] = .string(help) }

        let nearby = context.nearbyText
            .prefix(maxNearbyText)
            .map { String($0.prefix(maxNearbyTextLength)) }
        if !nearby.isEmpty { state["nearby_text"] = .strings(Array(nearby)) }

        return state
    }

    public static func questions(for candidates: [VaultField]) -> [String: JevQuestion] {
        var criteria = Dictionary(uniqueKeysWithValues: candidates.map { ($0.key, $0.detail) })
        criteria[noMatchKey] = "None of the stored fields fit this input."

        return [
            fieldQuestion: .choice(
                instructions: "Which stored personal-data field is this input asking the user to provide?",
                criteria: criteria
            ),
            // Asked independently of the choice so the safety gate does not depend
            // on the classification being right.
            sensitiveQuestion: .noul(
                instructions: "Is this input asking for financial or government-identifier information such as a payment card number, security code, bank account, or social security number?"
            ),
        ]
    }

    /// Narrows the vault to the keys worth asking about, seeded by whatever the
    /// local tier already suspected.
    public static func candidates(
        from fillable: [VaultField],
        localRanking: [ScoredKey],
        context: FieldContext
    ) -> [VaultField] {
        guard fillable.count > maxCandidates else { return fillable }

        let byKey = Dictionary(uniqueKeysWithValues: fillable.map { ($0.key, $0) })
        var ordered: [VaultField] = []
        var seen = Set<String>()

        func take(_ field: VaultField) {
            guard seen.insert(field.key).inserted else { return }
            ordered.append(field)
        }

        // 1. Anything the local matcher scored at all.
        for scored in localRanking {
            guard let field = byKey[scored.key] else { continue }
            take(field)
        }

        // 2. Lexical overlap between the field text and the key's label.
        let haystack = context.searchText
        let words = Set(haystack.split(separator: " ").map(String.init))
        for field in fillable where !seen.contains(field.key) {
            let labelWords = FieldContext.normalize(field.label).split(separator: " ").map(String.init)
            if labelWords.contains(where: { words.contains($0) }) { take(field) }
        }

        // 3. Top up from the same categories already represented, so the model
        //    can still say "it's the campus one, not the home one".
        let categories = Set(ordered.map(\.category))
        for field in fillable where !seen.contains(field.key) && categories.contains(field.category) {
            take(field)
        }

        return Array(ordered.prefix(maxCandidates))
    }

    // MARK: Call

    public func match(
        context: FieldContext,
        candidates: [VaultField]
    ) async throws -> MatchResult? {
        guard !candidates.isEmpty else { return nil }

        let answers = try await client.decide(
            state: Self.state(for: context),
            questions: Self.questions(for: candidates)
        )
        return Self.result(from: answers, candidates: candidates)
    }

    /// Split out from the network call so tests can drive it with recorded JSON.
    public static func result(
        from answers: [String: JevAnswer],
        candidates: [VaultField]
    ) -> MatchResult? {
        guard let field = answers[fieldQuestion], let choice = field.choice else { return nil }

        let sensitive = (answers[sensitiveQuestion]?.noul ?? 0) >= MatchThresholds.sensitive
        let validKeys = Set(candidates.map(\.key))

        let ranked = (field.probabilities ?? [:])
            .filter { validKeys.contains($0.key) }
            .map { ScoredKey(key: $0.key, score: $0.value) }
            .sorted { ($0.score, $0.key) > ($1.score, $1.key) }

        // Jev says nothing fits. Hand back its ranking anyway so the picker can
        // still open pre-sorted rather than alphabetically.
        guard choice != noMatchKey, validKeys.contains(choice) else {
            guard !ranked.isEmpty else { return nil }
            return MatchResult(
                key: ranked[0].key,
                confidence: 0,
                source: .jev,
                alternatives: Array(ranked.dropFirst()),
                looksSensitive: sensitive
            )
        }

        return MatchResult(
            key: choice,
            confidence: field.confidence ?? 0,
            source: .jev,
            alternatives: ranked.filter { $0.key != choice },
            looksSensitive: sensitive
        )
    }
}
