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
        for item in trace(context, fillable: fillable, hints: hints) {
            scores[item.key] = max(scores[item.key] ?? 0, item.score)
        }
        return scores
            .map { ScoredKey(key: $0.key, score: $0.value) }
            .sorted { ($0.score, $0.key) > ($1.score, $1.key) }
    }

    /// One reason a key was offered, and how strongly.
    struct Evidence: Sendable, Equatable {
        let key: String
        let score: Double
        let reason: String
    }

    /// Everything that fired for this field, in the order it fired. `match` keeps
    /// the best score per key; the matcher eval prints the whole list for a wrong
    /// answer, which is what makes a bad rule findable.
    func trace(
        _ context: FieldContext,
        fillable: Set<String>,
        hints: MatchHints = MatchHints()
    ) -> [Evidence] {
        var evidence: [Evidence] = []
        let chromium = ChromiumMatching.hits(context)
        let own = context.ownSearchText
        let all = context.searchText

        // Chromium only runs its card patterns inside a form it has already
        // recognised as a payment form, which is what keeps `verification` and
        // `exp.*date` from firing on "Verification code" or "workExperience …
        // startDate". Control sees one field at a time, so it asks the same
        // question of the field's own and nearby text instead.
        let inPaymentContext = Self.mentions(all, Self.paymentWords)

        // Chromium's "ignored" types say what a field is *not*: a search box, a
        // one-time code, a username. Only the field's own text counts — a
        // "Search" link elsewhere on the page says nothing about this box.
        let vetoes = chromium.filter(\.own).compactMap { hit in
            ChromiumMatching.veto(for: hit.type).map { (type: hit.type, veto: $0) }
        }

        func isVetoed(_ key: String) -> Bool {
            vetoes.contains { type, veto in
                // Inside a payment form, "Verification code" is the card's.
                // Chromium parses card fields before one-time codes for the
                // same reason.
                if type == .oneTimeCode, inPaymentContext, key.hasPrefix("card_") { return false }
                return veto.covers(key)
            }
        }

        func offer(_ key: String, _ score: Double, _ reason: @autoclosure () -> String) {
            guard fillable.contains(key), !isVetoed(key) else { return }
            evidence.append(Evidence(key: key, score: score, reason: reason()))
        }

        // Phrase rules. A hit on the field's own label scores full value; a hit
        // that only appears in surrounding page text is weaker evidence.
        for rule in Self.rules {
            if let phrase = rule.matchingPhrase(in: own, vetoedBy: own) {
                offer(rule.key, rule.confidence, "phrase \"\(phrase)\" in label")
            } else if let phrase = rule.matchingPhrase(in: all, vetoedBy: own) {
                // Evidence from surrounding page text only. Weighted so that even
                // a strong rule lands near the fill threshold rather than sailing
                // past it — ambient text is suggestive, not decisive.
                offer(rule.key, rule.confidence * 0.6, "phrase \"\(phrase)\" in nearby text")
            }
        }

        // Chromium's patterns, for the types that name a key outright. Control's
        // own vetoes still apply: "Emergency contact phone" is somebody else's.
        //
        // The specific beats the general, as it does for address components: a
        // label that names one part of a name ("contact.name.last") wants that
        // part, even though it also looks like a contact's full name.
        let namesAPart = chromium.contains { $0.own && [.firstName, .middleName, .middleInitial, .lastName].contains($0.type) }
        for hit in chromium {
            guard let key = ChromiumMatching.keys[hit.type] else { continue }
            if key == "full_name", namesAPart { continue }
            if Self.chromiumKeyVetoes[key, default: []].contains(where: { Self.contains(own, $0) }) { continue }
            if key.hasPrefix("card_"), !inPaymentContext { continue }
            let score = ChromiumMatching.rescale(hit.score)
            if hit.own {
                offer(key, score, "Chromium \(hit.type.rawValue) in \"\(hit.text)\"")
            } else {
                offer(key, score * 0.6, "Chromium \(hit.type.rawValue) in nearby \"\(hit.text)\"")
            }
        }

        // Scoped components: "City" alone is meaningless, "City" under a "Billing
        // address" heading is not. Resolve the component, then the scope. When a
        // label names several components, the most specific wins: "Address line
        // 2" is line 2, not the generic "address" it also contains.
        let ownComponents = [Self.addressComponent(in: own)]
            + chromium.filter(\.own).map(ChromiumMatching.addressComponent(for:))
        let nearbyComponents = [Self.addressComponent(in: all)]
            + chromium.filter { !$0.own }.map(ChromiumMatching.addressComponent(for:))
        // A country *code* is a dialling or ISO code, not the country's name.
        let isCountryCode = Self.mentions(own, ["country code"])
        func usable(_ components: [AddressComponent?]) -> [AddressComponent] {
            components.compactMap { $0 }.filter { !($0 == .country && isCountryCode) }
        }
        if let component = usable(ownComponents).min() ?? usable(nearbyComponents).min() {
            let scope = Self.addressScope(in: own) ?? Self.addressScope(in: all)
            let why = "address \(component.suffix), scope \(scope?.prefix ?? "none")"
            offer("\(scope?.prefix ?? "home")_\(component.suffix)", scope == nil ? 0.60 : 0.92, why)
            if scope == nil {
                offer("campus_\(component.suffix)", 0.55, why)
                offer("billing_\(component.suffix)", 0.40, why)
            }
        }

        let chromiumSaysEmail = chromium.contains { $0.type == .email }
        if chromiumSaysEmail || Self.mentions(own, Self.emailTokens) || Self.mentions(all, Self.emailTokens) {
            let scoped = Self.mentions(own, ["school", "university", "edu", "academic", "campus", "student", "institution"])
                || Self.mentions(own, Array(hints.schoolTokens))
            let personal = Self.mentions(own, ["personal", "private", "home", "alternate"])
            if scoped { offer("email_school", 0.95, "email, school word in label") }
            if personal { offer("email_personal", 0.95, "email, personal word in label") }
            if !scoped && !personal {
                // Genuinely ambiguous for someone with both. Land in the confirm
                // band so the HUD shows both rather than picking wrong.
                offer("email_personal", 0.72, "email, unscoped")
                offer("email_school", 0.68, "email, unscoped")
            }
        }

        return evidence
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
        ///
        /// Returns the phrase that satisfied the rule rather than a Bool, so the
        /// eval's trace can say *which* phrase fired.
        func matchingPhrase(in haystack: String, vetoedBy veto: String) -> String? {
            guard !excluding.contains(where: { LocalMatcher.contains(veto, $0) }) else { return nil }
            return phrases.first { LocalMatcher.contains(haystack, $0) }
        }
    }

    static let emailTokens = ["email", "e mail", "mail address"]

    /// Evidence that a field belongs to a payment form.
    static let paymentWords = ["card", "credit", "debit", "cc", "cvv", "cvc", "csc", "cvn", "expir", "billing", "payment"]

    static let rules: [Rule] = [
        // Names — specific before general, with a hard veto on login handles.
        Rule(key: "preferred_name", phrases: ["preferred name", "preferred first name", "goes by", "go by", "nickname", "chosen name", "known as"], confidence: 0.95),
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
        Rule(key: "pronouns", phrases: ["pronoun"], confidence: 0.95),
        Rule(key: "date_of_birth", phrases: ["date of birth", "birth date", "birthdate", "birthday", "dob"], confidence: 0.95,
             // A form that splits a date into three boxes labels them "birthDate-month"
             // and friends. Each part is a fragment, not the date.
             excluding: ["month", "day", "year", "mm", "dd", "yyyy"]),

        // Contact
        Rule(key: "phone_mobile", phrases: ["phone", "mobile number", "cell", "telephone", "contact number"], confidence: 0.92,
             excluding: ["work phone", "office phone", "emergency"] + phonePartWords),

        // Education
        Rule(key: "university", phrases: ["university", "college", "school name", "institution", "current school", "where do you study", "school"], confidence: 0.88, excluding: ["email", "high school"]),
        Rule(key: "major_primary", phrases: ["major", "field of study", "course of study", "concentration", "degree program", "program of study"], confidence: 0.88, excluding: ["second", "double", "minor"]),
        Rule(key: "major_secondary", phrases: ["second major", "double major", "additional major", "other major"], confidence: 0.93),
        Rule(key: "degree_type", phrases: ["degree type", "degree level", "type of degree"], confidence: 0.92),
        Rule(key: "grad_year", phrases: ["graduation year", "grad year", "expected graduation", "class year", "year of graduation", "anticipated graduation"], confidence: 0.93),
        Rule(key: "class_standing", phrases: ["class standing", "year in school", "academic year", "current year"], confidence: 0.90),
        Rule(key: "student_id", phrases: ["student id", "student number", "sid"], confidence: 0.93,
             excluding: ["country", "state", "city", "zip", "postal", "phone", "email", "month", "day", "year"]),
        Rule(key: "gpa", phrases: ["gpa", "grade point", "grade average"], confidence: 0.95),

        // Professional
        Rule(key: "github_url", phrases: ["github"], confidence: 0.95),
        // `linkedInUrl` splits into "linked in url".
        Rule(key: "linkedin_url", phrases: ["linkedin", "linked in"], confidence: 0.95),
        Rule(key: "website_url", phrases: ["website", "portfolio", "personal site", "homepage", "personal url"], confidence: 0.88),
        Rule(key: "current_title", phrases: ["job title", "current title", "your title", "position title", "current role", "jobtitle", "current position"], confidence: 0.90),
        Rule(key: "current_org", phrases: ["employer", "company name", "current company", "organization name", "current employer"], confidence: 0.88),

        // Payment
        Rule(key: "card_number", phrases: ["card number", "credit card number", "debit card number"], confidence: 0.95),
        Rule(key: "card_cvv", phrases: ["cvv", "cvc", "security code", "card code", "csc"], confidence: 0.95),
        Rule(key: "card_exp", phrases: ["expiration", "expiry", "exp date", "mm yy", "mm yyyy", "valid thru", "card exp", "cc exp"], confidence: 0.93,
             // A box for just the month or just the year wants that part.
             excluding: ["month", "year"]),
        Rule(key: "card_name", phrases: ["name on card", "cardholder", "card holder"], confidence: 0.95),
    ]

    /// Words in a field's own text that stop a Chromium pattern from naming this
    /// key — the phrase rules' vetoes, for the same reasons. Not "user": that
    /// veto exists for "username", which Chromium's NAME_IGNORED already
    /// catches precisely, and as a bare word it kills `ssoUser.firstName`.
    static let chromiumKeyVetoes: [String: [String]] = [
        "given_name": ["preferred"],
        "full_name": ["card", "company", "organization", "school", "university", "file", "domain", "event", "product", "nick"],
        "phone_mobile": ["work phone", "office phone", "emergency"] + phonePartWords,
        "card_exp": ["month", "year"],
        // "Organization industry", "Company size": about the organisation, not its name.
        "current_org": ["industry"],
    ]

    /// A field for one piece of a number — `phonePart2`, a country-code picker —
    /// wants that piece, and the whole number in it is wrong. Chromium tells
    /// these apart by field order; one field at a time, the words are the tell.
    static let phonePartWords = ["part", "country code", "phone code", "phone country", "extension"]

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
        if mentions(haystack, ["billing", "bill to", "payment", "credit card"]) { return .billing }
        if mentions(haystack, ["permanent", "home address", "parent", "family address"]) { return .home }
        if mentions(haystack, ["campus", "current address", "local address", "term address", "school address", "term time"]) { return .campus }
        return nil
    }

    /// One part of an address, ordered most specific first. A label that names
    /// several ("Address line 2" is also an "address") means the first.
    enum AddressComponent: Int, Comparable, Sendable {
        case street2, street1, postal, city, state, country
        /// A bare "address" with nothing more specific: line 1, but it loses to
        /// every other component.
        case streetGeneric

        var suffix: String {
            switch self {
            case .street2: "street_2"
            case .street1, .streetGeneric: "street_1"
            case .postal: "postal"
            case .city: "city"
            case .state: "state"
            case .country: "country"
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The component half of every address key: `home_city`, `billing_postal`.
    static let addressKeySuffixes = ["street_1", "street_2", "city", "state", "postal", "country"]

    static func addressComponent(in haystack: String) -> AddressComponent? {
        // Field names run the number into the word: `street2`, `addressLine1`.
        if mentions(haystack, ["address line 2", "address 2", "apt", "apartment", "suite", "unit number", "line 2",
                               "line2", "street2", "address2", "addr2"]) { return .street2 }
        if mentions(haystack, ["address line 1", "address 1", "street address", "line 1", "street", "line1"]) { return .street1 }
        if mentions(haystack, ["zip", "postal code", "post code", "postcode"]) { return .postal }
        // "Locality" is what address APIs call the city.
        if mentions(haystack, ["city", "town", "locality"]) { return .city }
        // "Subdivision" is the ISO 3166-2 word for a state or province.
        if mentions(haystack, ["state", "province", "region", "subdivision"]) { return .state }
        if mentions(haystack, ["country"]) { return .country }
        if mentions(haystack, ["address"]) { return .streetGeneric }
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
