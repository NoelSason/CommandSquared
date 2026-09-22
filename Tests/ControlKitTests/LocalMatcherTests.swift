import XCTest
@testable import ControlKit

/// Fixture-driven tests over the deterministic tier.
///
/// The negative cases matter as much as the positive ones: a label the rules
/// can't resolve must score *below* the confirm threshold so the coordinator
/// escalates to Jev instead of quietly filling the wrong thing.
final class LocalMatcherTests: XCTestCase {
    private let matcher = LocalMatcher()
    private let allKeys = Set(VaultSchema.builtIn.map(\.key))

    private func context(
        label: String? = nil,
        placeholder: String? = nil,
        nearby: [String] = [],
        app: String = "Safari",
        domain: String? = "example.com"
    ) -> FieldContext {
        FieldContext(
            appName: app,
            bundleID: "com.apple.Safari",
            domain: domain,
            role: "AXTextField",
            label: label,
            placeholder: placeholder,
            nearbyText: nearby
        )
    }

    private func top(_ context: FieldContext) -> ScoredKey? {
        matcher.match(context, fillable: allKeys).first
    }

    // MARK: Unambiguous labels resolve locally

    func testUnambiguousLabelsResolveWithHighConfidence() {
        let cases: [(String, String)] = [
            ("First name", "given_name"),
            ("Legal first name", "given_name"),
            ("Last name", "family_name"),
            ("Surname", "family_name"),
            ("Middle initial", "middle_name"),
            ("Preferred first name", "preferred_name"),
            ("What name do you go by?", "preferred_name"),
            ("Phone number", "phone_mobile"),
            ("Mobile number", "phone_mobile"),
            ("Date of birth", "date_of_birth"),
            ("Expected graduation year", "grad_year"),
            ("Student ID", "student_id"),
            ("GPA", "gpa"),
            ("Second major", "major_secondary"),
            ("GitHub", "github_url"),
            ("LinkedIn profile", "linkedin_url"),
            ("Card number", "card_number"),
            ("CVV", "card_cvv"),
            ("Name on card", "card_name"),
        ]

        for (label, expected) in cases {
            let result = top(context(label: label))
            XCTAssertEqual(result?.key, expected, "label: \(label)")
            XCTAssertGreaterThanOrEqual(
                result?.score ?? 0,
                MatchThresholds.autoInsert,
                "\(label) should resolve without asking"
            )
        }
    }

    // MARK: Negative guards

    func testUsernameIsNotAName() {
        let result = top(context(label: "Username"))
        XCTAssertNotEqual(result?.key, "given_name")
        XCTAssertNotEqual(result?.key, "family_name")
        XCTAssertNotEqual(result?.key, "full_name")
    }

    func testPreferredNameDoesNotSatisfyTheFirstNameRule() {
        let ranked = matcher.match(context(label: "Preferred name"), fillable: allKeys)
        XCTAssertEqual(ranked.first?.key, "preferred_name")
        XCTAssertFalse(ranked.contains { $0.key == "given_name" })
    }

    func testCompanyNameIsNotTheUsersName() {
        let result = top(context(label: "Company name"))
        XCTAssertEqual(result?.key, "current_org")
    }

    func testBareNameFillsFullNameAndOffersAlternatives() {
        // "Name" on its own is ambiguous, but guessing then learning beats asking:
        // it fills the likeliest reading and leaves the others a press away.
        let ranked = matcher.match(context(label: "Name"), fillable: allKeys)
        XCTAssertEqual(ranked.first?.key, "full_name")
        XCTAssertGreaterThanOrEqual(ranked.first?.score ?? 0, MatchThresholds.autoInsert)
        // What to cycle to is assembled by FillController, which appends every
        // remaining fillable field after the match — so there is always somewhere
        // to go even when this tier only recognises one candidate.
    }

    // MARK: Email scoping

    func testSchoolAndPersonalEmailAreDistinguished() {
        XCTAssertEqual(top(context(label: "University email"))?.key, "email_school")
        XCTAssertEqual(top(context(label: "Student email address"))?.key, "email_school")
        XCTAssertEqual(top(context(label: "Personal email"))?.key, "email_personal")
    }

    func testBareEmailFillsPersonalAndKeepsSchoolNext() {
        let ranked = matcher.match(context(label: "Email address"), fillable: allKeys)
        XCTAssertEqual(ranked.first?.key, "email_personal")
        XCTAssertEqual(ranked.dropFirst().first?.key, "email_school",
                       "the other email must be the very next candidate, one press away")
    }

    // MARK: Address scoping — the case nearby text exists for

    func testAddressComponentTakesItsScopeFromNearbyText() {
        let billing = context(label: "City", nearby: ["Billing address"])
        XCTAssertEqual(top(billing)?.key, "billing_city")

        let permanent = context(label: "ZIP", nearby: ["Permanent address"])
        XCTAssertEqual(top(permanent)?.key, "home_postal")

        let campus = context(label: "Street address", nearby: ["Current campus address"])
        XCTAssertEqual(top(campus)?.key, "campus_street_1")
    }

    func testUnscopedAddressDefaultsToHomeAndKeepsCampusNext() {
        let ranked = matcher.match(context(label: "City"), fillable: allKeys)
        XCTAssertEqual(ranked.first?.key, "home_city")
        XCTAssertEqual(ranked.dropFirst().first?.key, "campus_city")
    }

    func testScopedAddressBeatsTheUnscopedDefaultDecisively() {
        // The gap matters: a heading should not merely nudge the ranking, it should
        // put the scoped key far enough ahead that it fills without hesitation.
        let scoped = top(context(label: "City", nearby: ["Current campus address"]))
        let unscoped = top(context(label: "City"))
        XCTAssertEqual(scoped?.key, "campus_city")
        XCTAssertGreaterThan((scoped?.score ?? 0) - (unscoped?.score ?? 0), 0.25)
    }

    func testNothingIsProposedForAnUnrelatedField() {
        // The floor still has to exist, or every stray box gets a name in it.
        let ranked = matcher.match(context(label: "Favourite colour"), fillable: allKeys)
        XCTAssertTrue(ranked.isEmpty, "got \(ranked.map(\.key))")
    }

    func testAddressLineTwoBeatsAddressLineOne() {
        XCTAssertEqual(top(context(label: "Address line 2", nearby: ["Home address"]))?.key, "home_street_2")
        XCTAssertEqual(top(context(label: "Apt, suite, unit", nearby: ["Home address"]))?.key, "home_street_2")
    }

    // MARK: Fillable filtering

    func testEmptyFieldsAreNeverProposed() {
        let ranked = matcher.match(context(label: "GitHub"), fillable: ["email_personal"])
        XCTAssertFalse(ranked.contains { $0.key == "github_url" })
    }

    // MARK: Sensitivity heuristic

    func testSensitivityHeuristicCatchesPaymentFields() {
        XCTAssertTrue(LocalMatcher.looksSensitive(context(label: "Card number")))
        XCTAssertTrue(LocalMatcher.looksSensitive(context(label: "Security code")))
        XCTAssertTrue(LocalMatcher.looksSensitive(context(label: "Social security number")))
        XCTAssertFalse(LocalMatcher.looksSensitive(context(label: "First name")))
    }

    // MARK: Normalization

    func testNormalizationCollapsesPunctuationAndCase() {
        // Punctuation becomes a space rather than vanishing, so "E-mail" reads as
        // "e mail" — which is why the email rule carries that spelling too.
        XCTAssertEqual(FieldContext.normalize("E-mail address *"), "e mail address")
        XCTAssertEqual(FieldContext.normalize("  ZIP / Postal  Code  "), "zip postal code")
    }

    func testHyphenatedEmailStillMatches() {
        let ranked = matcher.match(context(label: "E-mail address"), fillable: allKeys)
        XCTAssertTrue(ranked.contains { $0.key.hasPrefix("email_") })
    }

    func testSignatureIgnoresContentsAndAmbientText() {
        let a = context(label: "Email", nearby: ["Step 1"])
        var b = a
        b.nearbyText = ["Step 2"]
        b.isEmpty = false
        XCTAssertEqual(a.signature, b.signature)

        var c = a
        c.label = "Phone"
        XCTAssertNotEqual(a.signature, c.signature)
    }
}
