import Foundation

/// Runs `ChromiumPatterns` against a field and says what they found.
///
/// The patterns decide *what kind* of field this is. Control then decides which
/// of its keys that means: an email hit still goes through Control's school /
/// personal split, and an address hit still takes its scope from the section
/// heading. See `FieldContext.patternLabelParts` for why the patterns see raw
/// text rather than `searchText`.
enum ChromiumMatching {
    struct Hit: Sendable, Equatable {
        let type: ChromiumFieldType
        /// Chromium's own score, before rescaling.
        let score: Double
        /// On the field's own label, placeholder, help or name — as opposed to
        /// nearby page text, which is weaker evidence.
        let own: Bool
        /// From a label-only pattern: the broad "…address…" catch-all, which
        /// should lose to anything more specific.
        let labelOnly: Bool
        /// The text it matched in, for the eval's trace.
        let text: String
    }

    /// Chromium scores run 0.8–1.4 for the English patterns ported here; this
    /// maps them onto 0.85–0.97. The order is preserved, every hit on a field's
    /// own label clears `MatchThresholds.autoInsert` and the importer's
    /// pre-tick bar (0.85), and keys a pattern names directly stay below
    /// Control's own specialisations (0.95–0.96), so "Preferred first name" and
    /// "First and last name" still resolve the way Control means them to.
    static func rescale(_ chromiumScore: Double) -> Double {
        0.69 + 0.2 * chromiumScore
    }

    /// Every pattern that matched, own attributes first.
    static func hits(_ context: FieldContext) -> [Hit] {
        let label = context.patternLabelParts
        let name = context.patternNameParts
        let nearby = context.patternNearbyParts

        var hits: [Hit] = []
        for pattern in compiled {
            let ownText = label.first(where: pattern.matches)
                ?? (pattern.source.labelOnly ? nil : name.first(where: pattern.matches))
            if let ownText {
                hits.append(Hit(type: pattern.source.type, score: pattern.source.score, own: true,
                                labelOnly: pattern.source.labelOnly, text: ownText))
            } else if let nearbyText = nearby.first(where: pattern.matches) {
                hits.append(Hit(type: pattern.source.type, score: pattern.source.score, own: false,
                                labelOnly: pattern.source.labelOnly, text: nearbyText))
            }
        }
        return hits
    }

    // MARK: Mapping onto Control

    /// Types that name one Control key outright.
    static let keys: [ChromiumFieldType: String] = [
        .firstName: "given_name",
        .middleName: "middle_name",
        .middleInitial: "middle_name",
        .lastName: "family_name",
        .fullName: "full_name",
        .nameGeneric: "full_name",
        .phone: "phone_mobile",
        .company: "current_org",
        .nameOnCard: "card_name",
        .cardNumber: "card_number",
        .cardVerificationCode: "card_cvv",
        .cardExpiry: "card_exp",
        .cardExpiryTwoDigitYear: "card_exp",
        .cardExpiryFourDigitYear: "card_exp",
    ]

    /// Which keys a recognised non-fillable type rules out.
    enum Veto: Sendable, Equatable {
        case names, addresses, payment, everything

        func covers(_ key: String) -> Bool {
            switch self {
            case .names: ["given_name", "middle_name", "family_name", "full_name"].contains(key)
            case .addresses: LocalMatcher.addressKeySuffixes.contains { key.hasSuffix("_" + $0) }
            case .payment: key.hasPrefix("card_")
            case .everything: true
            }
        }
    }

    static func veto(for type: ChromiumFieldType) -> Veto? {
        switch type {
        case .nameIgnored, .honorificPrefix: .names
        case .addressNameIgnored, .addressLookup, .attentionIgnored: .addresses
        case .searchTerm, .oneTimeCode, .promoCode, .price, .numericQuantity: .everything
        case .iban, .passport, .giftCard, .debitGiftCard, .loyaltyMembership: .payment
        default: nil
        }
    }

    /// The vetoes one piece of text carries on its own, with the type that
    /// raised each. Lowercased raw text, as `patternNearbyParts` gives it.
    static func vetoes(in text: String) -> [(type: ChromiumFieldType, veto: Veto)] {
        compiled.compactMap { pattern in
            guard let veto = veto(for: pattern.source.type), pattern.matches(text) else { return nil }
            return (pattern.source.type, veto)
        }
    }

    /// Types that name an address component. Which address — home, campus or
    /// billing — is Control's call, from the section heading.
    static func addressComponent(for hit: Hit) -> LocalMatcher.AddressComponent? {
        switch hit.type {
        case .addressLine1: hit.labelOnly ? .streetGeneric : .street1
        case .addressLine2, .apartmentNumber: .street2
        case .city: .city
        case .state: .state
        case .zip: .postal
        case .country: .country
        default: nil
        }
    }

    // MARK: Compiled patterns

    struct CompiledPattern: Sendable {
        let source: ChromiumPattern
        let positive: NSRegularExpression
        let negative: NSRegularExpression?

        func matches(_ text: String) -> Bool {
            let range = NSRange(text.startIndex..., in: text)
            guard positive.firstMatch(in: text, range: range) != nil else { return false }
            return negative?.firstMatch(in: text, range: range) == nil
        }
    }

    /// A match must begin a word, the same property `LocalMatcher.contains`
    /// enforces for phrases — `city` must not fire inside `velocity`, `sid`
    /// inside `residential`. The second branch lets a pattern that itself
    /// starts with punctuation (`_cc`, `^\(`) match where it stands.
    static func wordStart(_ pattern: String) -> String {
        #"(?:(?<![\p{L}\p{N}])|(?![\p{L}\p{N}]))(?:"# + pattern + ")"
    }

    /// Compiled once. The patterns are fixed data, and `ChromiumPatternTests`
    /// compiles every one of them, so a failure here is a bad edit to
    /// `ChromiumPatterns`, caught before it ships.
    static let compiled: [CompiledPattern] = ChromiumPatterns.english.map { pattern in
        CompiledPattern(
            source: pattern,
            positive: try! NSRegularExpression(pattern: wordStart(pattern.positive), options: .caseInsensitive),
            // Negatives veto, so they keep Chromium's plain search: vetoing too
            // often is the safe direction.
            negative: pattern.negative.map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }
        )
    }
}
