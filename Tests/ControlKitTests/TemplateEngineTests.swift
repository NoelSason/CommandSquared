import XCTest
@testable import ControlKit

final class TemplateEngineTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private func environment(
        on dateString: String = "2026-09-22 10:30",
        clipboard: String? = nil,
        values: [String: String] = [:]
    ) -> TemplateEngine.Environment {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        return TemplateEngine.Environment(
            now: formatter.date(from: dateString)!,
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX"),
            clipboard: clipboard,
            value: { values[$0] }
        )
    }

    private func expand(_ template: String, _ environment: TemplateEngine.Environment) -> String {
        TemplateEngine.expand(template, in: environment).text
    }

    // MARK: Vault values

    func testVaultKeysAreSubstituted() {
        let env = environment(values: ["full_name": "Noel Sason", "email_school": "noel_sason@berkeley.edu"])
        XCTAssertEqual(
            expand("Hi, I'm {full_name}, reachable at {email_school}.", env),
            "Hi, I'm Noel Sason, reachable at noel_sason@berkeley.edu."
        )
    }

    func testUnknownPlaceholdersAreLeftAloneRatherThanDeleted() {
        // Silently dropping something it did not understand would be the worst
        // possible failure for text about to be sent to someone.
        let result = TemplateEngine.expand("Dear {hiring_manager}, I'm {full_name}.",
                                           in: environment(values: ["full_name": "Noel"]))
        XCTAssertEqual(result.text, "Dear {hiring_manager}, I'm Noel.")
        XCTAssertEqual(result.unresolved, ["hiring_manager"])
        XCTAssertFalse(result.isFullyResolved)
    }

    func testAnEmptyVaultValueCountsAsUnresolved() {
        let result = TemplateEngine.expand("{gpa}", in: environment(values: [:]))
        XCTAssertEqual(result.text, "{gpa}")
        XCTAssertEqual(result.unresolved, ["gpa"])
    }

    // MARK: Dates

    func testBareDateAndTime() {
        XCTAssertEqual(expand("{date}", environment()), "09/22/2026")
        // Asserted loosely: the separator before AM is a narrow no-break space in
        // current ICU, and pinning that is testing Foundation, not this code.
        let time = expand("{time}", environment())
        XCTAssertTrue(time.hasPrefix("10:30"), time)
        XCTAssertTrue(time.hasSuffix("AM"), time)
    }

    func testCustomDateFormats() {
        XCTAssertEqual(expand("{date:MMMM d, yyyy}", environment()), "September 22, 2026")
        XCTAssertEqual(expand("{date:yyyy-MM-dd}", environment()), "2026-09-22")
        XCTAssertEqual(expand("{date:EEEE}", environment()), "Tuesday")
    }

    func testDateArithmetic() {
        XCTAssertEqual(expand("{date+7d}", environment()), "09/29/2026")
        XCTAssertEqual(expand("{date-1d}", environment()), "09/21/2026")
        XCTAssertEqual(expand("{date+2w}", environment()), "10/06/2026")
        XCTAssertEqual(expand("{date+1y}", environment()), "09/22/2027")
    }

    func testMonthArithmeticClampsRatherThanOverflowing() {
        // 31 January plus one month is 28 February, not 3 March.
        XCTAssertEqual(expand("{date+1mo}", environment(on: "2026-01-31 09:00")), "02/28/2026")
    }

    func testDayArithmeticKeepsTheClockTimeAcrossADSTChange() {
        // 1 November 2026 to 2 November crosses the US clock change. Calendar
        // arithmetic keeps 09:00; adding 86,400 seconds would not.
        let env = environment(on: "2026-11-01 09:00")
        XCTAssertEqual(expand("{date+1d}", env), "11/02/2026")
        XCTAssertEqual(expand("{date+1d:HH:mm}", environment(on: "2026-11-01 09:00")), "09:00")
    }

    func testNonsenseDateExpressionsAreLeftAlone() {
        let result = TemplateEngine.expand("{date+banana}", in: environment())
        XCTAssertEqual(result.text, "{date+banana}")
    }

    // MARK: Clipboard and cursor

    func testClipboardIsSubstituted() {
        XCTAssertEqual(expand("Ref: {clipboard}", environment(clipboard: "ORD-7429")), "Ref: ORD-7429")
    }

    func testAnEmptyClipboardIsUnresolvedRatherThanBlank() {
        let result = TemplateEngine.expand("{clipboard}", in: environment(clipboard: nil))
        XCTAssertEqual(result.unresolved, ["clipboard"])
    }

    func testCursorMarkerIsRemovedAndItsPositionReported() {
        let result = TemplateEngine.expand("Dear {cursor},\n\nRegards", in: environment())
        XCTAssertEqual(result.text, "Dear ,\n\nRegards")
        XCTAssertEqual(result.cursorOffset, 5)
    }

    func testCursorOffsetCountsWhatTheAccessibilityAPICounts() {
        // Accessibility text ranges are UTF-16. "👋" is one Character but two
        // UTF-16 units, so a Character count put the caret one place early.
        let result = TemplateEngine.expand("👋 {cursor}!", in: environment())
        XCTAssertEqual(result.text, "👋 !")
        XCTAssertEqual(result.cursorOffset, 3)
        XCTAssertEqual(result.text.utf16.count - (result.cursorOffset ?? 0), 1, "one unit back from the end")
    }

    // MARK: Robustness

    func testUnclosedBracesAreLeftExactlyAsWritten() {
        XCTAssertEqual(expand("50% of {x", environment()), "50% of {x")
        XCTAssertEqual(expand("a } b", environment()), "a } b")
    }

    func testTextWithoutPlaceholdersIsUntouched() {
        let text = "Nothing to see here — no braces at all."
        XCTAssertEqual(expand(text, environment()), text)
        XCTAssertFalse(TemplateEngine.containsPlaceholder(text))
    }

    func testPlaceholderDetection() {
        XCTAssertTrue(TemplateEngine.containsPlaceholder("my email is {email_personal}"))
        XCTAssertFalse(TemplateEngine.containsPlaceholder("{ unclosed"))
        XCTAssertFalse(TemplateEngine.containsPlaceholder(""))
    }

    func testWhitespaceInsidePlaceholdersIsTolerated() {
        let env = environment(values: ["full_name": "Noel Sason"])
        XCTAssertEqual(expand("{ full_name }", env), "Noel Sason")
    }

    func testAdjacentPlaceholders() {
        let env = environment(values: ["given_name": "Noel", "family_name": "Sason"])
        XCTAssertEqual(expand("{given_name}{family_name}", env), "NoelSason")
    }
}
