import XCTest
@testable import ControlKit

final class ValueFormatterTests: XCTestCase {
    private func context(label: String? = nil, placeholder: String? = nil) -> FieldContext {
        FieldContext(
            appName: "Safari",
            bundleID: "com.apple.Safari",
            label: label,
            placeholder: placeholder
        )
    }

    // MARK: Phone

    func testPhoneMimicsThePlaceholdersSeparators() {
        let stored = "+15551234567"
        XCTAssertEqual(
            ValueFormatter.format(stored, kind: .phone, context: context(placeholder: "(555) 555-5555")),
            "(555) 123-4567"
        )
        XCTAssertEqual(
            ValueFormatter.format(stored, kind: .phone, context: context(placeholder: "555-555-5555")),
            "555-123-4567"
        )
        XCTAssertEqual(
            ValueFormatter.format(stored, kind: .phone, context: context(placeholder: "5555555555")),
            "5551234567"
        )
    }

    func testPhoneFallsBackToTheCommonUSFormat() {
        XCTAssertEqual(
            ValueFormatter.format("+15551234567", kind: .phone, context: context(label: "Phone")),
            "(555) 123-4567"
        )
    }

    func testPhoneKeepsInternationalFormWhenTheFieldAsksForIt() {
        XCTAssertEqual(
            ValueFormatter.format("+15551234567", kind: .phone, context: context(label: "Phone with country code")),
            "+15551234567"
        )
    }

    // MARK: Dates

    func testDateDefaultsToUSOrderAndFollowsHints() {
        let stored = "2006-03-14"
        XCTAssertEqual(ValueFormatter.format(stored, kind: .date, context: context(label: "Date of birth")), "03/14/2006")
        XCTAssertEqual(ValueFormatter.format(stored, kind: .date, context: context(placeholder: "DD/MM/YYYY")), "14/03/2006")
        XCTAssertEqual(ValueFormatter.format(stored, kind: .date, context: context(placeholder: "YYYY-MM-DD")), "2006-03-14")
    }

    // MARK: Expiry

    func testExpiryShortensTheYearUnlessTheFieldWantsAllFour() {
        XCTAssertEqual(ValueFormatter.format("09/2029", kind: .monthYear, context: context(placeholder: "MM/YY")), "09/29")
        XCTAssertEqual(ValueFormatter.format("09/2029", kind: .monthYear, context: context(placeholder: "MM/YYYY")), "09/2029")
        XCTAssertEqual(ValueFormatter.format("09/2029", kind: .monthYear, context: context(label: "Expiration")), "0929")
    }

    // MARK: Card

    func testCardNumberIsBareDigitsUnlessThePlaceholderIsGrouped() {
        XCTAssertEqual(
            ValueFormatter.format("4242424242424242", kind: .cardNumber, context: context(placeholder: "1234 5678 9012 3456")),
            "4242 4242 4242 4242"
        )
        XCTAssertEqual(
            ValueFormatter.format("4242424242424242", kind: .cardNumber, context: context(label: "Card number")),
            "4242424242424242"
        )
    }

    // MARK: URLs

    func testHandleFieldsGetTheHandleNotTheURL() {
        XCTAssertEqual(
            ValueFormatter.format("https://github.com/noelsason", kind: .url, context: context(label: "GitHub username")),
            "noelsason"
        )
        XCTAssertEqual(
            ValueFormatter.format("https://github.com/noelsason", kind: .url, context: context(label: "GitHub profile")),
            "https://github.com/noelsason"
        )
    }

    // MARK: Pass-through

    func testPlainKindsAreOnlyTrimmed() {
        XCTAssertEqual(ValueFormatter.format("  Noel  ", kind: .text, context: context()), "Noel")
        XCTAssertEqual(ValueFormatter.format("a@b.edu", kind: .email, context: context()), "a@b.edu")
    }
}
