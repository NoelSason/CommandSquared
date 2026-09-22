import Foundation

/// Deterministic field matching. No network, no model, no latency.
///
/// This tier exists to make the common case instant: "Email address", "Phone
/// number", "ZIP" and friends are not interesting judgment calls and should never
/// cost an API round trip. Anything it can't resolve cleanly it scores low on
/// purpose, so the coordinator escalates to Jev instead of guessing.
/// Facts about *this* user that make an ambiguous label unambiguous.
///
/// "Berkeley email" is only obviously a school address if you know where the
/// person goes. A fixed keyword list ("school", "university", "edu") cannot know
/// that, and adding every institution name in the world is not a plan. The
/// user's own stored values already say it, so the matcher reads them.
public struct MatchHints: Sendable, Equatable {
    /// Words that identify this user's institution — from their university name
    /// and the domain of their school address.
    public var schoolTokens: Set<String>

    public init(schoolTokens: Set<String> = []) {
        self.schoolTokens = schoolTokens
    }

    /// Words too common to identify anything.
    private static let ignored: Set<String> = [
        "university", "college", "school", "institute", "of", "the", "at", "and",
        "com", "edu", "org", "net", "ac", "uk", "ca", "us", "mail", "email",
    ]

    public init(university: String?, schoolEmail: String?) {
        var tokens = Set<String>()

        for word in FieldContext.normalize(university ?? "").split(separator: " ") {
            let token = String(word)
            if token.count >= 2, !Self.ignored.contains(token) { tokens.insert(token) }
        }

        if let host = schoolEmail?.split(separator: "@").last {
            for label in FieldContext.normalize(String(host)).split(separator: " ") {
                let token = String(label)
                if token.count >= 3, !Self.ignored.contains(token) { tokens.insert(token) }
            }
        }

        schoolTokens = tokens
    }
}

public struct LocalMatcher: Sendable {
    public init() {}

    /// Ranked candidates, best first. `fillable` restricts results to keys that
    /// actually hold a value.
    public func match(
        _ context: FieldContext,
        fillable: Set<String>,
        hints: MatchHints = MatchHints()
    ) -> [ScoredKey] {
        var scores: [String: Double] = [:]

        func offer(_ key: String, _ score: Double) {
            guard fillable.contains(key) else { return }
            scores[key] = max(scores[key] ?? 0, score)
        }

        let own = context.ownSearchText
        let all = context.searchText

        // Phrase rules. A hit on the field's own label scores full value; a hit
        // that only appears in surrounding page text is weaker evidence.
        for rule in Self.rules {
            if rule.matches(own, vetoedBy: own) {
                offer(rule.key, rule.confidence)
            } else if rule.matches(all, vetoedBy: own) {
                // Evidence from surrounding page text only. Weighted so that even
                // a strong rule lands near the fill threshold rather than sailing
                // past it — ambient text is suggestive, not decisive.
                offer(rule.key, rule.confidence * 0.6)
            }
        }

        // Scoped components: "City" alone is meaningless, "City" under a "Billing
        // address" heading is not. Resolve the component, then the scope.
        if let component = Self.addressComponent(in: own) ?? Self.addressComponent(in: all) {
            let scope = Self.addressScope(in: own) ?? Self.addressScope(in: all)
            offer("\(scope?.prefix ?? "home")_\(component)", scope == nil ? 0.60 : 0.92)
            if scope == nil {
                offer("campus_\(component)", 0.55)
                offer("billing_\(component)", 0.40)
            }
        }

        if Self.mentions(own, Self.emailTokens) || Self.mentions(all, Self.emailTokens) {
            let scoped = Self.mentions(own, ["school", "university", "edu", "academic", "campus", "student", "institution"])
                || Self.mentions(own, Array(hints.schoolTokens))
            let personal = Self.mentions(own, ["personal", "private", "home", "alternate"])
            if scoped { offer("email_school", 0.95) }
            if personal { offer("email_personal", 0.95) }
            if !scoped && !personal {
                // Genuinely ambiguous for someone with both. Land in the confirm
                // band so the HUD shows both rather than picking wrong.
                offer("email_personal", 0.72)
                offer("email_school", 0.68)
            }
        }

        return scores
            .map { ScoredKey(key: $0.key, score: $0.value) }
            .sorted { ($0.score, $0.key) > ($1.score, $1.key) }
    }

    /// A cheap stand-in for Jev's sensitivity question, used when Jev isn't reached.
    public static func looksSensitive(_ context: FieldContext) -> Bool {
        mentions(context.searchText, [
            "card number", "credit card", "debit card", "cvv", "cvc", "security code",
            "expiration", "expiry", "card exp", "billing", "account number", "routing",
            "social security", "ssn", "tax id", "passport",
        ])
    }

    // MARK: Rules

    struct Rule: Sendable {
        let key: String
        let phrases: [String]
        let confidence: Double
        /// Phrases that veto the rule — "username" must not satisfy a "name" rule.
        var excluding: [String] = []

        /// The veto is checked against the field's *own* text only. A stray word
        /// in surrounding page text should not disqualify a rule that the field's
        /// actual label satisfies.
        func matches(_ haystack: String, vetoedBy veto: String) -> Bool {
            guard !excluding.contains(where: { LocalMatcher.contains(veto, $0) }) else { return false }
            return phrases.contains { LocalMatcher.contains(haystack, $0) }
        }
    }

    static let emailTokens = ["email", "e mail", "mail address"]

    static let rules: [Rule] = [
        // Names — specific before general, with a hard veto on login handles.
        Rule(key: "preferred_name", phrases: ["preferred name", "preferred first name", "goes by", "go by", "nickname", "chosen name"], confidence: 0.95),
        Rule(key: "given_name", phrases: ["first name", "given name", "forename", "legal first"], confidence: 0.95, excluding: ["preferred", "last", "user"]),
        Rule(key: "family_name", phrases: ["last name", "surname", "family name", "legal last"], confidence: 0.95, excluding: ["user"]),
        Rule(key: "middle_name", phrases: ["middle name", "middle initial"], confidence: 0.95),
        Rule(key: "full_name", phrases: ["full name", "legal name", "your name", "name on file"], confidence: 0.90, excluding: ["user", "first", "last", "middle", "preferred", "card", "company", "school", "organization"]),
        // A label naming *both* halves wants the whole thing. "Name (First &
        // Last)" is the single most common way a form asks, and the guard that
        // stops "First name" matching a full name was vetoing it.
        Rule(key: "full_name", phrases: ["first last", "first and last", "first name and last name",
                                         "first middle last", "last first"], confidence: 0.96,
             excluding: ["user", "card", "company", "organization"]),
        Rule(key: "full_name", phrases: ["name"], confidence: 0.58, excluding: ["user", "first", "last", "middle", "preferred", "go by", "goes by", "card", "company", "school", "university", "organization", "file", "nick", "domain", "event", "product"]),
        Rule(key: "pronouns", phrases: ["pronoun"], confidence: 0.95),
        Rule(key: "date_of_birth", phrases: ["date of birth", "birth date", "birthdate", "birthday", "dob"], confidence: 0.95,
             // A form that splits a date into three boxes labels them "birthDate-month"
             // and friends. Each part is a fragment, not the date.
             excluding: ["month", "day", "year", "mm", "dd", "yyyy"]),

        // Contact
        Rule(key: "phone_mobile", phrases: ["phone", "mobile number", "cell", "telephone", "contact number"], confidence: 0.92, excluding: ["work phone", "office phone", "emergency"]),

        // Education
        Rule(key: "university", phrases: ["university", "college", "school name", "institution", "current school", "where do you study"], confidence: 0.88, excluding: ["email", "high school"]),
        Rule(key: "major_primary", phrases: ["major", "field of study", "course of study", "concentration", "degree program", "program of study"], confidence: 0.88, excluding: ["second", "double", "minor"]),
        Rule(key: "major_secondary", phrases: ["second major", "double major", "additional major", "other major"], confidence: 0.93),
        Rule(key: "degree_type", phrases: ["degree type", "degree level", "type of degree"], confidence: 0.92),
        Rule(key: "grad_year", phrases: ["graduation year", "grad year", "expected graduation", "class year", "year of graduation", "anticipated graduation"], confidence: 0.93),
        Rule(key: "class_standing", phrases: ["class standing", "year in school", "academic year", "current year"], confidence: 0.90),
        Rule(key: "student_id", phrases: ["student id", "student number", "sid"], confidence: 0.93,
             excluding: ["country", "state", "city", "zip", "postal", "phone", "email", "month", "day", "year"]),
        Rule(key: "gpa", phrases: ["gpa", "grade point"], confidence: 0.95),

        // Professional
        Rule(key: "github_url", phrases: ["github"], confidence: 0.95),
        Rule(key: "linkedin_url", phrases: ["linkedin"], confidence: 0.95),
        Rule(key: "website_url", phrases: ["website", "portfolio", "personal site", "homepage", "personal url"], confidence: 0.88),
        Rule(key: "current_title", phrases: ["job title", "current title", "your title", "position title", "current role"], confidence: 0.90),
        Rule(key: "current_org", phrases: ["employer", "company name", "current company", "organization name", "current employer"], confidence: 0.88),

        // Payment
        Rule(key: "card_number", phrases: ["card number", "credit card number", "debit card number"], confidence: 0.95),
        Rule(key: "card_cvv", phrases: ["cvv", "cvc", "security code", "card code", "csc"], confidence: 0.95),
        Rule(key: "card_exp", phrases: ["expiration", "expiry", "exp date", "mm yy", "mm yyyy", "valid thru"], confidence: 0.93),
        Rule(key: "card_name", phrases: ["name on card", "cardholder", "card holder"], confidence: 0.95),
    ]

    // MARK: Scoped address handling

    enum AddressScope: Sendable {
        case home, campus, billing

        var prefix: String {
            switch self {
            case .home: "home"
            case .campus: "campus"
            case .billing: "billing"
            }
        }
    }

    static func addressScope(in haystack: String) -> AddressScope? {
        if mentions(haystack, ["billing", "bill to", "payment address"]) { return .billing }
        if mentions(haystack, ["permanent", "home address", "parent", "family address"]) { return .home }
        if mentions(haystack, ["campus", "current address", "local address", "term address", "school address", "term time"]) { return .campus }
        return nil
    }

    static func addressComponent(in haystack: String) -> String? {
        if mentions(haystack, ["address line 2", "address 2", "apt", "apartment", "suite", "unit number", "line 2"]) { return "street_2" }
        if mentions(haystack, ["address line 1", "address 1", "street address", "line 1", "street"]) { return "street_1" }
        if mentions(haystack, ["zip", "postal code", "post code", "postcode"]) { return "postal" }
        if mentions(haystack, ["city", "town"]) { return "city" }
        if mentions(haystack, ["state", "province", "region"]) { return "state" }
        if mentions(haystack, ["country"]) { return "country" }
        if mentions(haystack, ["address"]) { return "street_1" }
        return nil
    }

    static func mentions(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { contains(haystack, $0) }
    }

    /// Phrase matching that starts at a word boundary.
    ///
    /// A plain substring test is wrong in a way that is hard to spot and easy to
    /// ship: "sid" is inside "re**sid**ential", so a field named
    /// `residentialFirstName` imported as a student ID. Requiring the phrase to
    /// *begin* a word fixes that while still matching "zip" inside "zipcode",
    /// which is a real and common spelling.
    static func contains(_ haystack: String, _ phrase: String) -> Bool {
        // The haystack is already normalised to space-separated lowercase words.
        (" " + haystack).contains(" " + phrase)
    }
}
