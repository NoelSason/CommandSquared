import XCTest
@testable import ControlKit

/// The ported Chromium patterns, one golden example each way per type, plus the
/// two properties the port had to get right: patterns see raw text, and every
/// match begins a word.
final class ChromiumPatternTests: XCTestCase {
    private func matches(_ type: ChromiumFieldType, _ text: String) -> Bool {
        ChromiumMatching.compiled.contains { $0.source.type == type && $0.matches(text) }
    }

    func testEveryPatternCompiles() {
        XCTAssertEqual(ChromiumMatching.compiled.count, ChromiumPatterns.english.count)
        for pattern in ChromiumPatterns.english {
            XCTAssertNoThrow(try NSRegularExpression(pattern: ChromiumMatching.wordStart(pattern.positive)), pattern.type.rawValue)
            if let negative = pattern.negative {
                XCTAssertNoThrow(try NSRegularExpression(pattern: negative), pattern.type.rawValue)
            }
        }
    }

    func testEveryTypeHasAPattern() {
        let ported = Set(ChromiumPatterns.english.map(\.type))
        XCTAssertEqual(ported, Set(ChromiumFieldType.allCases))
    }

    /// One text each type must match and one it must not, on lowercased raw text.
    func testGoldenExamples() {
        let cases: [(ChromiumFieldType, match: String, noMatch: String)] = [
            (.firstName, "first name", "last name"),
            (.middleName, "middle name", "first name"),
            (.middleInitial, "m.i.", "mind"),
            (.lastName, "surname", "surname2"),
            (.fullName, "full name", "project-name"),
            (.nameGeneric, "name", "username"),
            (.email, "e-mail", "female"),
            (.phone, "mobile", "saxophone"),
            (.company, "company name", "accompany"),
            (.addressLine1, "address-line-1", "dress size"),
            (.addressLine2, "address_line2", "address line 1"),
            (.apartmentNumber, "apartment", "department"),
            (.city, "city", "velocity"),
            (.state, "state", "united states"),
            (.zip, "zipcode", "billing.zip"),
            (.country, "country", "county"),
            (.nameOnCard, "cardholder name", "card number"),
            (.cardNumber, "card number", "cardigan"),
            (.cardVerificationCode, "cvv", "security question"),
            (.cardExpiry, "expiration date", "experience"),
            (.cardExpiryTwoDigitYear, "mm/yy", "mm/yyyy"),
            (.cardExpiryFourDigitYear, "mm/yyyy", "mm/yy"),
            (.nameIgnored, "username", "surname"),
            (.honorificPrefix, "salutation", "salutation and given name"),
            (.addressNameIgnored, "address nickname", "email address type"),
            (.addressLookup, "address lookup", "look up"),
            (.attentionIgnored, "attn", "attendance"),
            (.searchTerm, "search", "research"),
            (.oneTimeCode, "otp", "hotpot"),
            (.promoCode, "promo code", "promotion"),
            (.price, "price", "priceless"),
            (.numericQuantity, "quantity", "weight"),
            (.iban, "iban", "cuban"),
            (.passport, "passport number", "password"),
            (.giftCard, "gift card", "gift message"),
            (.debitGiftCard, "visa gift card", "visa card"),
            (.loyaltyMembership, "frequent flyer number", "membership type"),
        ]
        XCTAssertEqual(Set(cases.map(\.0)), Set(ChromiumFieldType.allCases), "every type needs a golden pair")
        for (type, positive, negative) in cases {
            XCTAssertTrue(matches(type, positive), "\(type.rawValue) should match \"\(positive)\"")
            XCTAssertFalse(matches(type, negative), "\(type.rawValue) should not match \"\(negative)\"")
        }
    }

    // MARK: Word starts

    func testAMatchMustBeginAWord() {
        // The property `LocalMatcher.contains` has for phrases, kept for patterns.
        XCTAssertFalse(matches(.city, "capacity"))
        XCTAssertFalse(matches(.city, "ethnicity"))
        XCTAssertFalse(matches(.searchTerm, "research"))
        XCTAssertTrue(matches(.zip, "zipcode"), "a pattern may still end mid-word")
    }

    func testAPatternThatStartsWithPunctuationMatchesWhereItStands() throws {
        // Chromium's PHONE_COUNTRY_CODE uses `_cc`; the wrapper must not demand a
        // word start before an underscore.
        let regex = try NSRegularExpression(pattern: ChromiumMatching.wordStart("_cc"))
        let text = "phone_cc"
        XCTAssertNotNil(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
    }

    // MARK: Raw text, not normalised text

    func testPunctuatedEmailSpellingsAllResolveToEmail() {
        let matcher = LocalMatcher()
        let keys = Set(VaultSchema.builtIn.map(\.key))
        for label in ["E-mail", "e_mail", "E.mail"] {
            let context = FieldContext(appName: "Safari", bundleID: "com.apple.Safari", label: label)
            XCTAssertEqual(matcher.match(context, fillable: keys).first?.key.hasPrefix("email_"), true, label)
        }
        for name in ["user.email", "e-mail", "EmailAddress"] {
            XCTAssertEqual(matcher.match(VaultImporter.context(forFieldName: name), fillable: keys).first?.key.hasPrefix("email_"), true, name)
        }
    }

    func testNormalisingFirstWouldChangeTheAnswer() {
        // The design decision, pinned both ways: `(?<!\.)zip` deliberately skips
        // `billing.zip`. `normalize()` turns the dot into a space, and on that
        // text the same pattern fires — so the patterns must see raw text.
        XCTAssertFalse(matches(.zip, "billing.zip"))
        XCTAssertTrue(matches(.zip, FieldContext.normalize("billing.zip")))

        // Anchors are per attribute: `^name` is a whole label starting "name",
        // not a word somewhere in `searchText`'s joined string.
        XCTAssertTrue(matches(.nameGeneric, "name"))
        XCTAssertFalse(matches(.nameGeneric, "project-name"))
    }

    func testAFieldNameIsMatchedAsWrittenAndSplitAtHumps() {
        let context = VaultImporter.context(forFieldName: "billingCity")
        XCTAssertEqual(context.patternNameParts, ["billingcity", "billing city"])
        // `fname` is only whole in the unsplit form; `city` only begins a word in
        // the split one. Both find their type.
        XCTAssertTrue(ChromiumMatching.hits(VaultImporter.context(forFieldName: "fName")).contains { $0.type == .firstName })
        XCTAssertTrue(ChromiumMatching.hits(context).contains { $0.type == .city })
    }

    // MARK: Scores

    func testRescalingKeepsOrderAndLandsAboveTheFillThreshold() {
        let scores = Set(ChromiumPatterns.english.map(\.score)).sorted()
        let rescaled = scores.map(ChromiumMatching.rescale)
        XCTAssertEqual(rescaled, rescaled.sorted(), "order preserved")
        for score in scores where score >= 0.8 {
            XCTAssertGreaterThanOrEqual(ChromiumMatching.rescale(score), MatchThresholds.autoInsert)
            XCTAssertGreaterThanOrEqual(ChromiumMatching.rescale(score) + 1e-9, 0.85, "imports stay pre-ticked")
        }
    }

    func testControlsOwnSpecialisationsOutrankADirectPatternHit() {
        // Keys a pattern names directly must score below Control's own 0.95 rules,
        // or "Preferred first name" would fill the legal first name.
        let direct = ChromiumPatterns.english.filter { ChromiumMatching.keys[$0.type] != nil }
        for pattern in direct {
            XCTAssertLessThan(ChromiumMatching.rescale(pattern.score), 0.95, pattern.type.rawValue)
        }
        let matcher = LocalMatcher()
        let keys = Set(VaultSchema.builtIn.map(\.key))
        let context = FieldContext(appName: "Safari", bundleID: "com.apple.Safari", label: "Preferred first name")
        XCTAssertEqual(matcher.match(context, fillable: keys).first?.key, "preferred_name")
    }

    // MARK: Control's layer on top

    func testCardPatternsNeedAPaymentForm() {
        let matcher = LocalMatcher()
        let keys = Set(VaultSchema.builtIn.map(\.key))
        func top(_ label: String, nearby: [String] = []) -> String? {
            matcher.match(FieldContext(appName: "Safari", bundleID: "com.apple.Safari", label: label, nearbyText: nearby),
                          fillable: keys).first?.key
        }
        // Chromium's `verification` means a card code only inside a card form.
        XCTAssertNotEqual(top("Verification code"), "card_cvv")
        XCTAssertEqual(top("Verification code", nearby: ["Credit card"]), "card_cvv")
    }

    func testAnIgnoredTypeVetoesTheField() {
        let matcher = LocalMatcher()
        let keys = Set(VaultSchema.builtIn.map(\.key))
        for label in ["Search", "Promo code", "Company size", "One-time code (OTP)"] {
            let context = FieldContext(appName: "Safari", bundleID: "com.apple.Safari", label: label)
            XCTAssertTrue(matcher.match(context, fillable: keys).isEmpty, label)
        }
    }
}
