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

        func covered(_ key: String, by vetoes: [(type: ChromiumFieldType, veto: ChromiumMatching.Veto)]) -> Bool {
            vetoes.contains { type, veto in
                // Inside a payment form, "Verification code" is the card's.
                // Chromium parses card fields before one-time codes for the
                // same reason.
                if type == .oneTimeCode, inPaymentContext, key.hasPrefix("card_") { return false }
                return veto.covers(key)
            }
        }

        // A field about another person — an emergency contact, a guardian, the
        // second passenger — takes none of the user's own details. The section
        // counts as well as the label: "First name" under "Parent/Guardian
        // Information" is the guardian's.
        let aboutSomeoneElse = Self.mentions(own, Self.otherPersonWords)
            || [context.labelCell, context.sectionHeading].compactMap { $0 }
                .contains { Self.mentions(FieldContext.normalize($0), Self.otherPersonWords) }
            || Self.namesALaterPerson(context.fieldName)

        func isVetoed(_ key: String) -> Bool {
            if key == "date_of_birth", Self.namesPartOfADate(own) { return true }
            if key == "phone_mobile", Self.namesAPhonePiece(own) { return true }
            if Self.personalContactKeys.contains(key), Self.namesWorkContact(own) { return true }
            if aboutSomeoneElse, Self.isPersonal(key) { return true }
            return covered(key, by: vetoes)
        }

        // Nearby text can't veto what the field's own label says, but it does
        // veto what it suggests itself: "Gift card number" above a box is a
        // gift card's number, and "Work phone:" a work number, though neither
        // is the field's label. Each piece of nearby text answers only for the
        // evidence it produced.
        let nearbyParts = context.nearbyEvidence.map { (raw: FieldContext.lowercasedCollapsingWhitespace($0), words: FieldContext.normalize($0)) }
            .filter { !$0.words.isEmpty }
        var nearbyVetoes: [String: [(type: ChromiumFieldType, veto: ChromiumMatching.Veto)]] = [:]
        for part in nearbyParts where nearbyVetoes[part.raw] == nil {
            nearbyVetoes[part.raw] = ChromiumMatching.vetoes(in: part.raw)
        }

        /// `nearby` is the piece of nearby text the evidence came from, if any.
        func offer(_ key: String, _ score: Double, _ reason: @autoclosure () -> String, from nearby: String? = nil) {
            guard fillable.contains(key), !isVetoed(key) else { return }
            if let nearby, covered(key, by: nearbyVetoes[nearby] ?? []) { return }
            evidence.append(Evidence(key: key, score: score, reason: reason()))
        }

        // Phrase rules. A hit on the field's own label scores full value; a hit
        // that only appears in surrounding page text is weaker evidence.
        for rule in Self.rules {
            if let phrase = rule.matchingPhrase(in: own, vetoedBy: own) {
                offer(rule.key, rule.confidence, "phrase \"\(phrase)\" in label")
            } else if let (part, phrase) = nearbyParts.lazy.compactMap({ part in
                rule.matchingPhrase(in: part.words, vetoedBy: own + " | " + part.words).map { (part, $0) }
            }).first {
                offer(rule.key, rule.confidence * Self.nearbyWeight, "phrase \"\(phrase)\" in nearby text", from: part.raw)
            }
        }

        // A person's role before "name" is the user in that role: the candidate
        // on a job application, the driver on a car booking. Objects never get
        // here, so `project-name` and `repository-name` stay unmatched.
        if Self.namesAPersonInARole(own), !Self.mentions(own, Self.roleNameExclusions) {
            offer("full_name", 0.90, "a person's role before \"name\"")
        }

        // The end of a stint at school is the year the user graduates, or
        // expects to: "Last year attended", `colleges[0].endYYYY`. The section
        // can supply the "school" half, as it supplies an address's scope.
        let educationText = own + " | " + (context.sectionHeading.map(FieldContext.normalize) ?? "")
        if Self.mentions(own, Self.endYearPhrases), Self.mentions(educationText, Self.educationWords) {
            offer("grad_year", 0.93, "end year of a stint at school")
        }

        // A link field that says nothing about which link — `urls[0]`,
        // `profileLinks[1].link`, "Other links" — is one of the user's three.
        // Which one is a guess, so it asks, with the likeliest first, rather
        // than leave the picker empty. It never fills on its own.
        if Self.isUnqualifiedLink(own) {
            for (key, score) in Self.unqualifiedLinkKeys {
                offer(key, score, "link field that doesn't say which")
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
            if key == "current_org", Self.namesOrganisationContact(own) { continue }
            if key.hasPrefix("card_"), !inPaymentContext { continue }
            let score = ChromiumMatching.rescale(hit.score)
            if hit.own {
                offer(key, score, "Chromium \(hit.type.rawValue) in \"\(hit.text)\"")
            } else {
                let words = FieldContext.normalize(hit.text)
                if Self.chromiumKeyVetoes[key, default: []].contains(where: { Self.contains(words, $0) }) { continue }
                offer(key, score * Self.nearbyWeight, "Chromium \(hit.type.rawValue) in nearby \"\(hit.text)\"", from: hit.text)
            }
        }

        let emailInLabel = chromium.contains { $0.type == .email && $0.own } || Self.mentions(own, Self.emailTokens)
            || context.placeholderIsAnExampleEmail

        // Scoped components: "City" alone is meaningless, "City" under a "Billing
        // address" heading is not. Resolve the component, then the scope. When a
        // label names several components, the most specific wins: "Address line
        // 2" is line 2, not the generic "address" it also contains.
        let ownComponents = [Self.addressComponent(in: own)]
            + chromium.filter(\.own).map(ChromiumMatching.addressComponent(for:))
        // A bare "address" nearby names a section, not this field: "Delivery
        // address" sits above the phone boxes and the gift message too. It
        // counts only as the field's own label cell.
        let nearbyComponents = ([Self.addressComponent(in: all)]
            + chromium.filter { !$0.own }.map(ChromiumMatching.addressComponent(for:)))
            .filter { $0 != .streetGeneric }
            + [context.labelCell.map(FieldContext.normalize).flatMap { cell in
                // The label cell is the field's label, so an "Email address"
                // there is an email's address, as it is in `usable` below.
                Self.addressComponent(in: cell).flatMap { $0 == .streetGeneric && Self.mentions(cell, Self.emailTokens) ? nil : $0 }
            }]
        // A country *code* is a dialling or ISO code, not the country's name.
        let isCountryCode = Self.mentions(own, Self.countryCodeWords)
        // A county is not the state: Chromium's state pattern takes "county"
        // for the UK's counties, and the vault has none. "State/province/
        // region/county" still names the state.
        let isCountyOnly = Self.mentions(own, ["county"]) && !Self.mentions(own, ["state", "province", "region"])
        // "Email address" is an address, but not a street one. Chromium never
        // meets this: it types a field as an email before it looks for an
        // address. Without it, "Email address" under a "Billing information"
        // heading filled the billing street.
        // Line 3 and beyond have no key, and nor does a box for the whole
        // address, a landmark, or a name for the address. They'd otherwise
        // read as the generic "address" they also contain, and fill the street.
        let isALaterLine = Self.mentions(own, Self.laterLineWords + Self.notAStreetLineWords)
        // A birthplace isn't where the user lives, and the vault has none.
        let isABirthplace = Self.mentions(own, ["birth", "birthplace"])
        func usable(_ components: [AddressComponent?]) -> [AddressComponent] {
            guard !isABirthplace else { return [] }
            return components.compactMap { $0 }.filter {
                !($0 == .country && isCountryCode) && !($0 == .state && isCountyOnly)
                    && !($0 == .streetGeneric && emailInLabel)
                    && !(isALaterLine && [.street1, .street2, .streetGeneric].contains($0))
            }
        }
        let ownComponent = usable(ownComponents).min()
        if let component = ownComponent ?? usable(nearbyComponents).min() {
            // The field's own words first, then its section heading. Only when
            // capture found no heading at all does any scope word nearby count —
            // otherwise the "Permanent address" section above would claim the
            // campus fields below it.
            let headingScope = context.sectionHeading.map { Self.addressScope(in: FieldContext.normalize($0)) }
            let scope = Self.addressScope(in: own) ?? (headingScope ?? Self.addressScope(in: all))
            let weight = ownComponent == nil ? Self.nearbyWeight : 1
            let why = "address \(component.suffix), scope \(scope?.prefix ?? "none")"
                + (ownComponent == nil ? " (from nearby text)" : "")
            offer("\(scope?.prefix ?? "home")_\(component.suffix)", (scope == nil ? 0.60 : 0.92) * weight, why)
            if scope == nil {
                offer("campus_\(component.suffix)", 0.55 * weight, why)
                offer("billing_\(component.suffix)", 0.40 * weight, why)
            }
        }

        let emailNearby = chromium.contains { $0.type == .email } || Self.mentions(all, Self.emailTokens)
        if emailInLabel || emailNearby {
            // An email field in the section is not evidence that *this* field
            // wants one: "Username" under "Email address" is still a username.
            let weight = emailInLabel ? 1 : Self.nearbyWeight
            let scoped = Self.mentions(own, ["school", "university", "edu", "academic", "campus", "student", "institution"])
                || Self.mentions(own, Array(hints.schoolTokens))
            let personal = Self.mentions(own, ["personal", "private", "home", "alternate"])
            if scoped { offer("email_school", 0.95 * weight, "email, school word in label") }
            if personal { offer("email_personal", 0.95 * weight, "email, personal word in label") }
            if !scoped && !personal {
                // Genuinely ambiguous for someone with both. Land in the confirm
                // band so the HUD shows both rather than picking wrong.
                offer("email_personal", 0.72 * weight, "email, unscoped" + (emailInLabel ? "" : ", from nearby text"))
                offer("email_school", 0.68 * weight, "email, unscoped" + (emailInLabel ? "" : ", from nearby text"))
            }
        }

        return evidence
    }

    /// A cheap stand-in for Jev's sensitivity question, used when Jev isn't reached.
    public static func looksSensitive(_ context: FieldContext) -> Bool {
        mentions(context.searchText, [
            "card number", "credit card", "debit card", "cvv", "cvc", "security code",
            "expiration", "expiry", "card exp", "billing", "account number", "routing",
            "social security", "ssn", "tax id", "passport", "known traveler", "known traveller", "ktn",
            "trusted traveler", "precheck", "global entry", "redress",
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

    /// What evidence found only in surrounding page text is worth, relative to
    /// the same evidence in the field's own label. Low enough that even the
    /// strongest rule (0.97 × 0.55 ≈ 0.53) stays under `autoInsert`: a heading
    /// or a neighbour's words can put a key first in the picker, but never fill
    /// it silently. At 0.6 they could, which is how "Date of birth" was filled
    /// from a nearby "What name do you go by?".
    static let nearbyWeight = 0.55

    /// One box of a split date — "birthDate-month", a placeholder of "MM" —
    /// wants that part only. A full format like "MM/DD/YYYY" names every part
    /// and is the whole date; it used to veto the date-of-birth rule too.
    static func namesPartOfADate(_ text: String) -> Bool {
        let parts = [["month", "mm"], ["day", "dd"], ["year", "yyyy", "yy"]]
        let named = parts.filter { mentions(text, $0) }.count
        return named > 0 && named < parts.count
    }

    /// Evidence that a field belongs to a payment form.
    static let paymentWords = ["card", "credit", "debit", "cc", "cvv", "cvc", "csc", "cvn", "expir", "billing", "payment"]

    static let rules: [Rule] = [
        // Names — specific before general, with a hard veto on login handles.
        // A card's or an address's nickname is a label for that thing, not
        // the name the user goes by.
        Rule(key: "preferred_name", phrases: ["preferred name", "preferred first name", "goes by", "go by", "nickname", "chosen name", "known as"], confidence: 0.95,
             excluding: ["card", "address", "account"]),
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
        // A form that splits the date into boxes labels them "birthDate-month" and
        // friends; `namesPartOfADate` keeps those from getting the whole date.
        Rule(key: "date_of_birth", phrases: ["date of birth", "birth date", "birthdate", "birthday", "dob"], confidence: 0.95),
        // TSA PreCheck's number. Global Entry, NEXUS and SENTRI members use
        // their PASSID, which is why "Global Entry" names it too. A frequent-
        // flyer or redress number never says any of these.
        Rule(key: "known_traveler_number", phrases: ["known traveler", "known traveller", "ktn", "trusted traveler",
                                                     "trusted traveller", "tsa precheck", "tsa pre check", "precheck",
                                                     "global entry"], confidence: 0.95),

        // Contact
        Rule(key: "phone_mobile", phrases: ["phone", "mobile number", "cell", "telephone", "contact number"], confidence: 0.92,
             excluding: ["work phone", "office phone", "emergency"] + otherPhoneWords),

        // Education
        // A school's city, state or address is where it is, not what it's called.
        Rule(key: "university", phrases: ["university", "college", "school name", "institution", "current school", "where do you study", "school"], confidence: 0.88,
             excluding: ["email", "high school", "city", "state", "country", "zip", "postal", "address"]),
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
             // A box for just the month or just the year wants that part. And
             // a card expiry never has a day: "dd/mm/yyyy" is a calendar date
             // that happens to contain "mm yy".
             excluding: ["month", "year"] + dayWords),
        Rule(key: "card_name", phrases: ["name on card", "cardholder", "card holder"], confidence: 0.95),
    ]

    /// Words in a field's own text that stop a Chromium pattern from naming this
    /// key — the phrase rules' vetoes, for the same reasons. Not "user": that
    /// veto exists for "username", which Chromium's NAME_IGNORED already
    /// catches precisely, and as a bare word it kills `ssoUser.firstName`.
    static let chromiumKeyVetoes: [String: [String]] = [
        "given_name": ["preferred"],
        "full_name": ["card", "company", "organization", "school", "university", "file", "domain", "event", "product", "nick"],
        "phone_mobile": ["work phone", "office phone", "emergency"] + otherPhoneWords,
        "card_exp": ["month", "year"] + dayWords,
        // "Organization industry", "Company size": about the organisation, not its name.
        "current_org": ["industry"],
    ]

    /// A work number or a work address is not the user's own: the vault holds a
    /// mobile and two personal emails. The qualifier has to come right before
    /// what it qualifies ("Business/Other Phone Number", `workEmail`), and the
    /// word between may not be "or": "Phone (home, work or mobile)" is a list
    /// of kinds, and still the user's phone.
    static let personalContactKeys: Set<String> = ["phone_mobile", "email_personal", "email_school"]

    private static let workContact = try! NSRegularExpression(
        pattern: #"\b(?:work|office|business)(?: (?!or\b|and\b)\w+)? (?:phone|telephone|tel|mobile|cell|number|email|e mail)\b"#
    )

    static func namesWorkContact(_ text: String) -> Bool {
        workContact.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// An organisation's phone, email or address is how to reach it, not its
    /// name: "Business/Other Phone Number", "Organization Address 1". Chromium's
    /// company pattern is just `business|organization`, which catches both. As
    /// with `namesWorkContact`, the organisation word comes first, so a field
    /// id like `mailingAddress_company` is still the company.
    private static let organisationContact = try! NSRegularExpression(
        pattern: #"\b(?:company|business|organi[sz]ation|employer)(?: \w+)? (?:phone|telephone|fax|email|e mail|address|number)\b"#
    )

    static func namesOrganisationContact(_ text: String) -> Bool {
        organisationContact.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The vault holds one phone. A form that asks for an alternate one has
    /// already asked for the main one, and that's where the number goes.
    /// (Alternate *emails* are fine: the user has two.)
    static let otherPhoneWords = ["alternate", "alternative", "secondary"]

    /// Words for someone other than the user. "Parent" is deliberately absent:
    /// a student's parents' address is their permanent address. So is a bare
    /// "guest" ("Guest checkout" is the user) and "recipient" (a ship-to
    /// recipient usually is too).
    static let otherPersonWords = [
        "emergency", "reference", "referee", "guardian", "beneficiary", "spouse", "minor",
        "invite", "additional guest", "other guest", "add guest", "guests", "tribute", "honoree",
        "gift recipient", "friend s", "friends", "co applicant", "cosigner", "co signer",
        "dependent", "email addresses",
    ]

    /// `passengers[1]`, `additionalTravelers.2.name`: a list of people where the
    /// user is the first. Field names count from zero; labels ("Passenger 1")
    /// count from one, so only the raw field name is read.
    private static let laterPerson = try! NSRegularExpression(
        pattern: #"(?:passenger|traveler|traveller|guest|attendee|occupant|rider)s?(?:\[|\.|_|-)0*[1-9]"#,
        options: .caseInsensitive
    )

    static func namesALaterPerson(_ fieldName: String?) -> Bool {
        guard let fieldName else { return false }
        return laterPerson.firstMatch(in: fieldName, range: NSRange(fieldName.startIndex..., in: fieldName)) != nil
    }

    /// The keys that hold the user's own person: names, contact, birth date,
    /// traveler number, addresses. Not their school, job or links, which a form about someone
    /// else doesn't ask for.
    static func isPersonal(_ key: String) -> Bool {
        ["given_name", "middle_name", "family_name", "full_name", "preferred_name", "pronouns",
         "date_of_birth", "known_traveler_number", "email_personal", "email_school", "phone_mobile"].contains(key)
            || addressKeySuffixes.contains { key.hasSuffix("_" + $0) }
    }

    /// Roles the user fills a form in. Someone else's roles (emergency contact,
    /// guardian, an additional driver) are vetoed separately.
    private static let roleName = try! NSRegularExpression(
        pattern: #"\b(?:candidate|applicant|student|patient|attendee|registrant|driver|traveler|traveller|member|subscriber|signer|signatory|legal)(?: \w+)? name\b"#
    )

    /// A part of the name, or a name that isn't a person's.
    static let roleNameExclusions = ["first", "last", "middle", "preferred", "user", "company", "organization", "school", "file", "card"]

    static func namesAPersonInARole(_ text: String) -> Bool {
        roleName.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The year something ended. With an education word, the graduation year.
    static let endYearPhrases = ["last year attended", "end year", "end yyyy", "end date year",
                                 "completion year", "year of completion", "year completed"]
    static let educationWords = ["education", "school", "college", "university", "degree", "academic"]

    /// Words that say a field wants a link without saying whose or which.
    static let linkWords: Set<String> = ["url", "urls", "link", "links"]
    static let genericLinkQualifiers: Set<String> = [
        "profile", "profiles", "social", "account", "accounts", "platform", "platforms",
        "personal", "optional", "other", "your", "my", "web", "value", "user", "additional",
    ]
    /// All below `MatchThresholds.autoInsert`: which link is a question, not a fact.
    static let unqualifiedLinkKeys: [(String, Double)] = [("linkedin_url", 0.45), ("website_url", 0.42), ("github_url", 0.40)]

    static func isUnqualifiedLink(_ text: String) -> Bool {
        let words = text.split(separator: " ").map(String.init).filter { $0 != "|" }
        guard words.contains(where: linkWords.contains) else { return false }
        return words.allSatisfy { linkWords.contains($0) || genericLinkQualifiers.contains($0) || $0.allSatisfy(\.isNumber) }
    }

    /// The day in a date format. A card expiry has none.
    static let dayWords = ["dd", "day"]

    /// A field for one piece of a number — `phonePart2`, a country-code picker,
    /// "Primary telephone number, exchange", "last four digits" — wants that
    /// piece, and the whole number in it is wrong. Chromium tells these apart by
    /// field order; one field at a time, the words are the tell.
    static let phonePartWords = [
        "part", "country code", "phone code", "phone country", "extension",
        "area", "exchange", "prefix", "suffix", "subscriber", "last four", "last 4", "first three",
    ]

    /// "Phone (with area code)" names a piece to say it wants the whole number.
    static let wholeNumberPhrases = ["with area code", "including area code", "incl area code"]

    static func namesAPhonePiece(_ text: String) -> Bool {
        let rest = wholeNumberPhrases.reduce(" " + text) { $0.replacingOccurrences(of: " " + $1, with: " ") }
        // "Ext." is a whole word; as a prefix it would catch `extraDetails`.
        return mentions(rest, phonePartWords) || (rest + " ").contains(" ext ")
    }

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

    /// Boxes that mention an address without being a line of one.
    static let notAStreetLineWords = ["full address", "landmark",
                                      "address name", "address label", "address nickname"]

    /// A dialling or ISO code for a country, not the country's name.
    static let countryCodeWords = ["country code", "phone country", "country phone", "phone code",
                                   "calling code", "dialing code", "dial code"]

    /// The third address line and beyond. The vault stores two.
    static let laterLineWords = ["address line 3", "address line 4", "address line 5", "address 3", "address 4",
                                 "line 3", "line 4", "line 5", "address3", "address4", "line3", "line4"]

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
