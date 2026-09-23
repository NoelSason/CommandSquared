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

extension LocalMatcherTests {
    /// A plain substring test made `residentialFirstName` import as a student ID,
    /// because "sid" hides inside "re*sid*ential".
    func testPhrasesMustBeginAWord() {
        XCTAssertFalse(LocalMatcher.contains("residential fist name", "sid"))
        XCTAssertFalse(LocalMatcher.contains("passport", "ssn"))
        XCTAssertTrue(LocalMatcher.contains("sid", "sid"))
        XCTAssertTrue(LocalMatcher.contains("student sid number", "sid"))
    }

    func testAPhraseMayStillEndMidWord() {
        // "zipcode" is one word in the wild and must still match "zip".
        XCTAssertTrue(LocalMatcher.contains("zipcode", "zip"))
        XCTAssertTrue(LocalMatcher.contains("emails", "email"))
    }

    func testResidentialNameFieldsResolveToNamesNotIDs() {
        let ranked = matcher.match(context(label: "residential first name"), fillable: allKeys)
        XCTAssertEqual(ranked.first?.key, "given_name")
        XCTAssertFalse(ranked.contains { $0.key == "student_id" })
    }
}

extension LocalMatcherTests {
    /// Google Forms' house style, and the shape that produced an empty match.
    func testALabelNamingBothHalvesWantsTheWholeName() {
        for label in [
            "Name (First & Last)",
            "Name (First and Last)",
            "First and Last Name",
            "Name: First Middle Last",
        ] {
            let result = top(context(label: label))
            XCTAssertEqual(result?.key, "full_name", "label: \(label)")
            XCTAssertGreaterThanOrEqual(result?.score ?? 0, MatchThresholds.autoInsert, "label: \(label)")
        }
    }

    func testGoogleFormsTrailingNoiseDoesNotBreakMatching() {
        // The accessibility label carries "Required question" on the end.
        let result = top(context(label: "Name (First & Last) Required question"))
        XCTAssertEqual(result?.key, "full_name")
    }

    func testEachHalfOnItsOwnStillResolvesToThatHalf() {
        XCTAssertEqual(top(context(label: "First name"))?.key, "given_name")
        XCTAssertEqual(top(context(label: "Last name"))?.key, "family_name")
    }
}

/// Rules added against Chromium's real-form corpus (matcher eval round 2).
extension LocalMatcherTests {
    private func heading(_ label: String?, heading: String, placeholder: String? = nil) -> FieldContext {
        var context = context(label: label, placeholder: placeholder, nearby: [heading])
        context.heading = heading
        return context
    }

    /// "Email address" under a "Billing information" heading filled the
    /// billing street: the "address" in it read as a street address.
    func testAnEmailAddressIsNotAStreetAddress() {
        let ranked = matcher.match(heading("Email Address:", heading: "Billing Information"), fillable: allKeys)
        XCTAssertEqual(ranked.first?.key, "email_personal")
        XCTAssertFalse(ranked.contains { $0.key.hasSuffix("_street_1") })
        // A street address in the same section is still one.
        XCTAssertEqual(top(heading("Address:", heading: "Billing Information"))?.key, "billing_street_1")
    }

    /// An immigration form's "Date of issue" (dd/mm/yyyy) filled the card
    /// expiry: "mm yy" hides inside a full date format.
    func testADateWithADayIsNotACardExpiry() {
        for (label, placeholder) in [("Date of issue", "dd/mm/yyyy o ddmmyy"), ("Expiration date", "dd/mm/yyyy")] {
            let ranked = matcher.match(context(label: label, placeholder: placeholder), fillable: allKeys)
            XCTAssertFalse(ranked.contains { $0.key == "card_exp" }, "label: \(label)")
        }
        XCTAssertEqual(top(context(label: "Expiration date", placeholder: "MM/YY"))?.key, "card_exp")
    }

    /// A field with no label of its own, as table-layout forms deliver it: the
    /// label cell right above it, then the section.
    private func labelCell(_ cell: String, section: String) -> FieldContext {
        var context = context(nearby: [cell, section])
        context.heading = cell
        return context
    }

    /// "Delivery Address" sat above the phone boxes and the gift message and
    /// made every one of them a street.
    func testABareAddressInAHeadingNamesTheSectionNotTheField() {
        let ranked = matcher.match(heading("Ext.", heading: "Delivery Address"), fillable: allKeys)
        XCTAssertFalse(ranked.contains { $0.key.hasSuffix("_street_1") })
        // The label cell of a label-less field is its label, and still counts.
        XCTAssertEqual(top(labelCell("*Address:", section: "Shipping"))?.key, "home_street_1")
    }

    /// "City:" in the cell beside the box is the field's label; "Billing
    /// Address" above it is the section, and says which city.
    func testALabelCellTakesItsScopeFromTheSectionAboveIt() {
        XCTAssertEqual(top(labelCell("City:", section: "Billing Address"))?.key, "billing_city")
        XCTAssertEqual(top(labelCell("Zip Code", section: "Shipping Address"))?.key, "home_postal")
        // An email's label cell is still an email, whatever the section.
        XCTAssertEqual(top(labelCell("Email Address*", section: "1 Billing Address"))?.key, "email_personal")
    }

    /// Split phone boxes filled the whole number into the exchange box.
    func testAPieceOfAPhoneNumberIsNotTheWholeNumber() {
        for label in [
            "Primary telephone number, exchange.",
            "Primary telephone number, last four digits.",
            "Enter three number exchange for your phone number.",
            "Area Code",
            "Ext.",
        ] {
            let ranked = matcher.match(context(label: label, nearby: ["Phone:"]), fillable: allKeys)
            XCTAssertFalse(ranked.contains { $0.key == "phone_mobile" }, "label: \(label)")
        }
        // Naming the area code to ask for it along with the number is the whole number.
        XCTAssertEqual(top(context(label: "Phone (with area code)"))?.key, "phone_mobile")
        // "Ext" is a whole word, not the start of `extraDetails`.
        XCTAssertEqual(top(context(label: "extra details phone mobile number"))?.key, "phone_mobile")
    }

    /// Nearby text vetoes what it suggests: the box under "Gift Card Number"
    /// is a gift card's, the one under "Work Phone:" a work number.
    func testNearbyTextVetoesItsOwnSuggestions() {
        let gift = matcher.match(labelCell("Gift Card Number", section: "Payment"), fillable: allKeys)
        XCTAssertFalse(gift.contains { $0.key == "card_number" })
        let work = matcher.match(labelCell("Work Phone:", section: "Contact"), fillable: allKeys)
        XCTAssertFalse(work.contains { $0.key == "phone_mobile" })
        // Without the veto word, the same nearby text still suggests the key.
        XCTAssertEqual(top(labelCell("Card Number", section: "Payment"))?.key, "card_number")
        // And nearby text never vetoes what the field's own label says.
        XCTAssertEqual(top(context(label: "Phone", nearby: ["Search"]))?.key, "phone_mobile")
    }

    /// The vault holds a mobile and two personal emails, none of them work ones.
    func testWorkContactDetailsAreNotTheUsers() {
        for label in ["Work email", "workEmail", "Business/Other Phone Number:", "Office phone number"] {
            let ranked = matcher.match(context(label: label), fillable: allKeys)
            XCTAssertFalse(ranked.contains { ["phone_mobile", "email_personal", "email_school"].contains($0.key) }, "label: \(label)")
        }
        // A list of kinds that happens to include "work" is still the user's phone.
        XCTAssertEqual(top(context(label: "Phone (home, work or mobile)"))?.key, "phone_mobile")
    }

    /// Chromium's company pattern is `business|organization`; an organisation's
    /// phone or address is how to reach it, not its name.
    func testAnOrganisationsContactDetailsAreNotItsName() {
        for label in ["Business/Other Phone Number:", "Organization Address 1", "Company phone"] {
            let ranked = matcher.match(context(label: label), fillable: allKeys)
            XCTAssertFalse(ranked.contains { $0.key == "current_org" }, "label: \(label)")
        }
        XCTAssertEqual(top(context(label: "Business name"))?.key, "current_org")
    }

    /// The vault holds one phone; an alternate-phone box sits beside the main one.
    func testAnAlternatePhoneIsNotTheMainNumber() {
        for label in ["Alternate Phone", "Alternative Number:", "Secondary phone"] {
            let ranked = matcher.match(context(label: label), fillable: allKeys)
            XCTAssertFalse(ranked.contains { $0.key == "phone_mobile" }, "label: \(label)")
        }
        let cell = matcher.match(labelCell("Alternate Phone:", section: "Contact"), fillable: allKeys)
        XCTAssertFalse(cell.contains { $0.key == "phone_mobile" })
        // The user has two emails, so an alternate email is still theirs.
        XCTAssertNotNil(matcher.match(context(label: "Alternate email address"), fillable: allKeys).first { $0.key.hasPrefix("email_") })
    }

    /// `urls[0]` and "Profile links" are one of the user's three links. Which
    /// one is a question, so Control asks rather than misses, and never fills.
    func testALinkFieldThatDoesNotSayWhichAsksAmongTheUsersLinks() {
        for name in ["urls[0]", "personal.profileLinks[1].link", "platformUrls.0.url", "user[profile_social_accounts][][url]"] {
            let ranked = matcher.match(VaultImporter.context(forFieldName: name), fillable: allKeys)
            XCTAssertEqual(ranked.first?.key, "linkedin_url", name)
            XCTAssertLessThan(ranked.first?.score ?? 1, MatchThresholds.autoInsert, name)
            XCTAssertGreaterThanOrEqual(ranked.first?.score ?? 0, MatchThresholds.confirm, name)
            XCTAssertEqual(Set(ranked.prefix(3).map(\.key)), ["linkedin_url", "website_url", "github_url"], name)
        }
        // A link that says what it is for is not one of the user's.
        for name in ["oauth_application[url]", "SITE_URL", "privacyPolicyUrl", "currentUser.instagramLink", "destination-url"] {
            let ranked = matcher.match(VaultImporter.context(forFieldName: name), fillable: allKeys)
            XCTAssertFalse(ranked.contains { $0.key.hasSuffix("_url") }, name)
        }
    }

    /// The candidate on a job application, the driver on a car booking: a
    /// person's role before "name" is the user in that role.
    func testAPersonsRoleBeforeNameIsTheUsersFullName() {
        for name in ["candidateName", "legal.legalAcknowledgmentName", "tripPreferencesRequests[0].carTripPreferencesRequest.driverName"] {
            XCTAssertEqual(matcher.match(VaultImporter.context(forFieldName: name), fillable: allKeys).first?.key, "full_name", name)
        }
        XCTAssertEqual(top(context(label: "Applicant name"))?.key, "full_name")
        // Objects have names too, and a system's sender is not the user.
        for name in ["project-name", "repository-name", "SMTP_SENDER_NAME"] {
            let ranked = matcher.match(VaultImporter.context(forFieldName: name), fillable: allKeys)
            XCTAssertFalse(ranked.contains { $0.key == "full_name" }, name)
        }
        // A part of the name still wants that part.
        XCTAssertEqual(top(context(label: "Candidate first name"))?.key, "given_name")
    }

    /// Another person's name, email or phone must never get the user's own.
    func testAFieldAboutSomeoneElseGetsNoneOfTheUsersDetails() {
        let personal: (ScoredKey) -> Bool = { LocalMatcher.isPersonal($0.key) }
        for label in ["Emergency contact name", "Minor's Date of Birth:", "Enter email addresses", "Reference phone"] {
            XCTAssertFalse(matcher.match(context(label: label), fillable: allKeys).contains(where: personal), label)
        }
        // The section says whose it is.
        XCTAssertFalse(matcher.match(heading("First Name *", heading: "Parent/Guardian Information"), fillable: allKeys)
            .contains(where: personal))
        // Field names count people from zero: the first passenger is the user.
        for name in ["frontierPassengers[1].Name.First", "additionalGuests.0.firstName"] {
            XCTAssertFalse(matcher.match(VaultImporter.context(forFieldName: name), fillable: allKeys).contains(where: personal), name)
        }
        XCTAssertEqual(matcher.match(VaultImporter.context(forFieldName: "frontierPassengers[0].Name.First"), fillable: allKeys).first?.key,
                       "given_name")
        // A parent's address is the permanent address, and a guest checkout is the user's.
        XCTAssertEqual(top(context(label: "Parent's home address"))?.key, "home_street_1")
        XCTAssertEqual(top(heading("Email address", heading: "Guest Checkout"))?.key, "email_personal")
    }

    /// The last year at school is the graduation year.
    func testTheEndYearOfAnEducationEntryIsTheGraduationYear() {
        for name in ["education-35--lastYearAttended-dateSectionYear-input", "appEducation.colleges[0].endYYYY"] {
            XCTAssertEqual(matcher.match(VaultImporter.context(forFieldName: name), fillable: allKeys).first?.key, "grad_year", name)
        }
        // The section can say it's about school.
        XCTAssertEqual(top(heading("End year", heading: "Education"))?.key, "grad_year")
        // Without school, an end year is anyone's.
        XCTAssertFalse(matcher.match(heading("End year", heading: "Work experience"), fillable: allKeys).contains { $0.key == "grad_year" })
    }

    /// The vault stores two address lines; "Address Line 3" read as the street.
    func testAThirdAddressLineHasNoKey() {
        for label in ["Address Line 3 (optional)", "Address Line 4:", "Billing address line 3 (Optional)"] {
            XCTAssertFalse(matcher.match(context(label: label), fillable: allKeys).contains { $0.key.contains("_street_") }, label)
        }
        XCTAssertEqual(top(context(label: "Address Line 2"))?.key, "home_street_2")
    }

    /// "Card's nickname e.g. My Visa" is a label for the card.
    func testAThingsNicknameIsNotWhatTheUserGoesBy() {
        for label in ["Card's nickname e.g. My Visa, Corporate card, etc", "Address nickname", "Card Nickname (optional)"] {
            XCTAssertFalse(matcher.match(context(label: label), fillable: allKeys).contains { $0.key == "preferred_name" }, label)
        }
        XCTAssertEqual(top(context(label: "Nickname"))?.key, "preferred_name")
    }

    /// The page's DOM id is weak evidence: it can suggest a key for a field with
    /// no label, but never fills on its own and never outranks the label.
    func testTheDOMIdSuggestsButNeverDecides() {
        var unlabelled = context()
        unlabelled.domIdentifier = "billingZipCode"
        let suggestion = top(unlabelled)
        XCTAssertEqual(suggestion?.key, "billing_postal")
        XCTAssertLessThan(suggestion?.score ?? 1, MatchThresholds.autoInsert)

        // `payment-credit-user-address-firstName` names its container too.
        var labelled = context(label: "First name")
        labelled.domIdentifier = "payment-credit-user-address-firstName"
        XCTAssertEqual(top(labelled)?.key, "given_name")

        // Framework ids change between page loads; the cache key must not.
        var reloaded = labelled
        reloaded.domIdentifier = ":r1a:"
        XCTAssertEqual(labelled.signature, reloaded.signature)
    }

    /// The vault has no county, and a dialling code is not the country.
    func testACountyIsNotTheStateAndACallingCodeIsNotTheCountry() {
        XCTAssertFalse(matcher.match(context(label: "County"), fillable: allKeys).contains { $0.key.hasSuffix("_state") })
        XCTAssertEqual(top(context(label: "State/province/region/county *"))?.key, "home_state")
        for label in ["Country Phone Code", "phoneCountry"] {
            XCTAssertFalse(matcher.match(context(label: label), fillable: allKeys).contains { $0.key.hasSuffix("_country") }, label)
        }
        XCTAssertEqual(top(context(label: "Country"))?.key, "home_country")
    }

    /// Boxes that say "address" without being a line of one.
    func testAWholeAddressALandmarkOrABirthplaceIsNotAStreetLine() {
        for label in ["fullAddress", "Landmark", "Address Name:"] {
            XCTAssertFalse(matcher.match(context(label: label), fillable: allKeys).contains { $0.key.contains("_street_") }, label)
        }
        XCTAssertFalse(matcher.match(context(label: "City or Town of Birth:"), fillable: allKeys).contains { $0.key.hasSuffix("_city") })
        // A validation message asking for a complete address is still line 1.
        XCTAssertEqual(top(context(label: "Address 1 Please enter a complete address."))?.key, "home_street_1")
    }

    /// "Name@yourmail.com" is an example value, not a name field.
    func testAnExampleEmailPlaceholderMakesAnEmailField() {
        let ranked = matcher.match(context(placeholder: "Name@yourmail.com"), fillable: allKeys)
        XCTAssertEqual(ranked.first?.key, "email_personal")
        XCTAssertFalse(ranked.contains { $0.key == "full_name" })
        // A placeholder that only mentions a name is still read.
        XCTAssertEqual(top(context(placeholder: "Full name"))?.key, "full_name")
    }

    /// TSA PreCheck's number, however the airline words it.
    func testAKnownTravelerNumberIsItsOwnField() {
        for label in ["Known Traveler Number", "Known Traveler Number (KTN)", "TSA PreCheck / Known Traveler #",
                      "Global Entry number", "Trusted traveler number"] {
            XCTAssertEqual(top(context(label: label))?.key, "known_traveler_number", label)
            XCTAssertTrue(LocalMatcher.looksSensitive(context(label: label)), label)
        }
        for name in ["knownTravelerNumber", "travelers[0].ktn"] {
            XCTAssertEqual(matcher.match(VaultImporter.context(forFieldName: name), fillable: allKeys).first?.key,
                           "known_traveler_number", name)
        }
        // A loyalty or redress number is a different number, and the second
        // traveller's is theirs.
        for label in ["Frequent flyer number", "Redress number"] {
            XCTAssertFalse(matcher.match(context(label: label), fillable: allKeys).contains { $0.key == "known_traveler_number" }, label)
        }
        XCTAssertFalse(matcher.match(VaultImporter.context(forFieldName: "travelers[1].knownTravelerNumber"), fillable: allKeys)
            .contains { $0.key == "known_traveler_number" })
    }

    /// A government id gets the same care as a card.
    func testTheKnownTravelerNumberIsAnIdentityFieldKeptAsSensitive() throws {
        let field = try XCTUnwrap(VaultSchema.field(for: "known_traveler_number"))
        XCTAssertEqual(field.category, .identity)
        XCTAssertTrue(field.sensitive)
        let imported = VaultImporter.fromBrowserAutofill([
            BrowserAutofillRow(fieldName: "knownTravelerNumber", value: "TT0000000", useCount: 3),
        ])
        XCTAssertFalse(imported.contains { $0.key == field.key }, "sensitive values are never imported")
    }

    /// The school's city is where it is, not what it's called.
    func testASchoolsPlaceIsNotItsName() {
        let ranked = matcher.match(VaultImporter.context(forFieldName: "appEducation.colleges[0].city"), fillable: allKeys)
        XCTAssertNotEqual(ranked.first?.key, "university")
        XCTAssertEqual(top(context(label: "College or university"))?.key, "university")
    }
}

final class MatchHintsTests: XCTestCase {
    private let matcher = LocalMatcher()
    private let allKeys = Set(VaultSchema.builtIn.map(\.key))

    private let hints = MatchHints(
        university: "University of California, Berkeley",
        schoolEmail: "noel_sason@berkeley.edu"
    )

    private func context(label: String) -> FieldContext {
        FieldContext(appName: "Brave", bundleID: "com.brave.Browser",
                     domain: "docs.google.com", role: "AXTextField", label: label)
    }

    private func top(_ label: String, hints: MatchHints) -> String? {
        matcher.match(context(label: label), fillable: allKeys, hints: hints).first?.key
    }

    func testTheInstitutionNameIdentifiesASchoolAddress() {
        // Without hints this is ambiguous and lands on the personal address.
        XCTAssertEqual(top("Berkeley email", hints: MatchHints()), "email_personal")
        XCTAssertEqual(top("Berkeley email", hints: hints), "email_school")
    }

    func testTheEmailDomainAloneIsEnough() {
        let domainOnly = MatchHints(university: nil, schoolEmail: "someone@berkeley.edu")
        XCTAssertEqual(top("Berkeley email address", hints: domainOnly), "email_school")
    }

    func testGenericWordsInTheInstitutionNameAreIgnored() {
        // "University of California" must not make every "college email" field a
        // school address by matching the word "university" back to itself.
        XCTAssertFalse(hints.schoolTokens.contains("university"))
        XCTAssertFalse(hints.schoolTokens.contains("of"))
        XCTAssertFalse(hints.schoolTokens.contains("edu"))
        XCTAssertTrue(hints.schoolTokens.contains("berkeley"))
    }

    func testAPersonalAddressIsStillPersonal() {
        XCTAssertEqual(top("Personal email", hints: hints), "email_personal")
    }

    func testTheBuiltInKeywordsStillWorkWithoutHints() {
        XCTAssertEqual(top("School email", hints: MatchHints()), "email_school")
        XCTAssertEqual(top("University email", hints: MatchHints()), "email_school")
    }

    func testAnEmptyVaultProducesNoHints() {
        let empty = MatchHints(university: nil, schoolEmail: nil)
        XCTAssertTrue(empty.schoolTokens.isEmpty)
    }
}
