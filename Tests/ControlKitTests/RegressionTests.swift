import XCTest
@testable import ControlKit

/// One test per bug that reached the user on 2026-09-22.
///
/// Every one of them was pure decision logic sitting in the app target, where
/// nothing could reach it. They are collected here rather than scattered so the
/// pattern stays visible: none of these needed a window to be caught.
final class RegressionTests: XCTestCase {

    // MARK: Cycling walked the entire vault

    func testCyclingOffersOnlyScoredCandidates() {
        // Shipped behaviour: cycling an email field reached date_of_birth, because
        // the cycle list appended every fillable key after the match.
        let result = MatchResult(
            key: "email_personal",
            confidence: 0.72,
            source: .local,
            alternatives: [ScoredKey(key: "email_school", score: 0.68)]
        )

        XCTAssertEqual(FillPlanner.cycleList(for: result), ["email_personal", "email_school"])
    }

    func testCycleListDropsDuplicateAlternatives() {
        let result = MatchResult(
            key: "email_personal",
            confidence: 0.9,
            source: .jev,
            alternatives: [
                ScoredKey(key: "email_personal", score: 0.9),
                ScoredKey(key: "email_school", score: 0.1),
            ]
        )
        XCTAssertEqual(FillPlanner.cycleList(for: result), ["email_personal", "email_school"])
    }

    // MARK: The picker collapsed to one row

    func testPickerAlwaysOffersEverythingAvailable() {
        // Shipped behaviour: narrowing the cycle list also narrowed the picker, so
        // a wrong remembered answer left a single row and no way out of it.
        let list = FillPlanner.pickerList(
            startingWith: ["university"],
            allFillable: ["university", "email_personal", "phone_mobile", "given_name"]
        )

        XCTAssertEqual(list.first, "university", "the match still leads")
        XCTAssertEqual(list.count, 4, "but every other stored value must be reachable")
        XCTAssertEqual(Set(list).count, list.count, "no duplicates")
    }

    func testPickerListSurvivesAnEmptyMatch() {
        let list = FillPlanner.pickerList(startingWith: [], allFillable: ["given_name", "family_name"])
        XCTAssertEqual(list, ["given_name", "family_name"])
    }

    // MARK: Passing through a candidate locked it in

    func testOnlyAnExplicitChoiceCountsAsDeliberate() {
        // Shipped behaviour: every cycle step recorded userConfirmed = true, so a
        // value merely passed through became permanent and protected.
        XCTAssertTrue(FillPlanner.isDeliberate(.manual))
        XCTAssertFalse(FillPlanner.isDeliberate(.cache))
        XCTAssertFalse(FillPlanner.isDeliberate(.local))
        XCTAssertFalse(FillPlanner.isDeliberate(.jev))
    }

    // MARK: Repeat-press semantics

    private func lastFill(
        ranked: [String] = ["email_personal", "email_school"],
        index: Int = 0,
        inserted: String = "noel@x.com",
        age: TimeInterval = 1
    ) -> FillPlanner.LastFill {
        FillPlanner.LastFill(
            signature: "sig",
            ranked: ranked,
            index: index,
            insertedText: inserted,
            at: Date().addingTimeInterval(-age)
        )
    }

    func testSecondPressCyclesToTheNextCandidate() {
        let action = FillPlanner.repeatAction(
            after: lastFill(),
            signature: "sig",
            fieldValue: "noel@x.com"
        )
        XCTAssertEqual(action, .cycle(to: "email_school", index: 1))
    }

    func testRunningOutOfCandidatesOpensTheFullListRatherThanWrapping() {
        let action = FillPlanner.repeatAction(
            after: lastFill(index: 1),
            signature: "sig",
            fieldValue: "noel@x.com"
        )
        XCTAssertEqual(action, .exhausted)
    }

    func testADifferentFieldIsNotARepeat() {
        let action = FillPlanner.repeatAction(
            after: lastFill(),
            signature: "other-field",
            fieldValue: "noel@x.com"
        )
        XCTAssertEqual(action, .fresh)
    }

    func testAnExpiredWindowIsNotARepeat() {
        let action = FillPlanner.repeatAction(
            after: lastFill(age: FillPlanner.cycleWindow + 1),
            signature: "sig",
            fieldValue: "noel@x.com"
        )
        XCTAssertEqual(action, .fresh)
    }

    func testRefusesToCycleOnceTheUserHasEdited() {
        // Cycling backspaces what Control inserted. If that text is no longer the
        // tail of the field, those backspaces would eat something the user typed.
        let action = FillPlanner.repeatAction(
            after: lastFill(),
            signature: "sig",
            fieldValue: "noel@x.com and then some"
        )
        XCTAssertEqual(action, .fresh)
    }

    // MARK: The same value went in twice

    func testASlowWriteIsNotTreatedAsAFailure() {
        // Shipped behaviour: "NoelNoel". The accessibility write had not landed yet
        // when it was checked, so typing was sent on top of it.
        XCTAssertFalse(InsertionPlan.landed(before: "", current: ""))
        XCTAssertTrue(InsertionPlan.landed(before: "", current: "Noel"))
    }

    func testEscalationStopsOnceAnythingHasLanded() {
        XCTAssertTrue(InsertionPlan.mayEscalate(before: "", current: ""))
        XCTAssertFalse(InsertionPlan.mayEscalate(before: "", current: "Noel"),
                       "something arrived late — typing now would duplicate it")
    }

    func testAFieldThatNeverReportsItsValueIsTakenAtItsWord() {
        XCTAssertTrue(InsertionPlan.landed(before: nil, current: nil))
        XCTAssertTrue(InsertionPlan.mayEscalate(before: nil, current: nil))
    }

    func testValueSetIsOfferedOnlyForAnEmptyField() {
        XCTAssertEqual(
            InsertionPlan.strategies(fieldIsEmpty: true, allowClipboard: true),
            [.axSelectedText, .axValue, .unicodeEvents, .clipboard]
        )
        XCTAssertFalse(
            InsertionPlan.strategies(fieldIsEmpty: false, allowClipboard: true).contains(.axValue),
            "setting the value replaces the field — never over existing text"
        )
    }

    /// "Please enter a valid phone number", with the number in the box: the
    /// value was set through accessibility, and the page's form never saw it.
    func testAWebFieldsValueIsNeverSetBehindThePagesBack() {
        let web = InsertionPlan.strategies(fieldIsEmpty: true, allowClipboard: true, inWebContent: true)
        XCTAssertFalse(web.contains(.axValue))
        XCTAssertEqual(web, [.axSelectedText, .unicodeEvents, .clipboard])
        // Native text fields have no page behind them, and keep the value write.
        XCTAssertTrue(InsertionPlan.strategies(fieldIsEmpty: true, allowClipboard: true, inWebContent: false).contains(.axValue))
    }

    func testSensitiveValuesNeverReachThePasteboard() {
        let ladder = InsertionPlan.strategies(fieldIsEmpty: true, allowClipboard: false)
        XCTAssertFalse(ladder.contains(.clipboard))
        XCTAssertFalse(ladder.contains { $0.isObservable })
    }

    func testTypingIsPreferredOverThePasteboard() {
        let ladder = InsertionPlan.strategies(fieldIsEmpty: false, allowClipboard: true)
        let typing = ladder.firstIndex(of: .unicodeEvents)!
        let clipboard = ladder.firstIndex(of: .clipboard)!
        XCTAssertLessThan(typing, clipboard, "keystrokes never touch the pasteboard; paste does")
    }

    // MARK: Suggestions fired in spreadsheets

    private func context(label: String?, secure: Bool = false) -> FieldContext {
        FieldContext(
            appName: "Numbers",
            bundleID: "com.apple.iWork.Numbers",
            role: "AXTextField",
            subrole: secure ? FieldContext.secureTextFieldSubrole : nil,
            label: label
        )
    }

    func testAnUnlabelledFieldIsNeverCompleted() {
        // Shipped behaviour: a spreadsheet cell starting with the same letters as
        // an email address got completed.
        XCTAssertEqual(
            SuggestionPolicy.refusal(context: context(label: nil), isDenied: false, typed: "noe", caretAtEnd: true),
            .unlabelledField
        )
    }

    func testSecureFieldsAndDeniedAppsAreRefusedFirst() {
        XCTAssertEqual(
            SuggestionPolicy.refusal(context: context(label: "Password", secure: true), isDenied: false, typed: "noe", caretAtEnd: true),
            .secureField
        )
        XCTAssertEqual(
            SuggestionPolicy.refusal(context: context(label: "Email"), isDenied: true, typed: "noe", caretAtEnd: true),
            .deniedApp
        )
    }

    func testCompletionNeedsAPrefixAndACaretAtTheEnd() {
        XCTAssertEqual(
            SuggestionPolicy.refusal(context: context(label: "Email"), isDenied: false, typed: "n", caretAtEnd: true),
            .tooFewCharacters
        )
        XCTAssertEqual(
            SuggestionPolicy.refusal(context: context(label: "Email"), isDenied: false, typed: "noe", caretAtEnd: false),
            .caretNotAtEnd
        )
    }

    func testALabelledFormFieldIsAllowed() {
        XCTAssertNil(
            SuggestionPolicy.refusal(context: context(label: "Email address"), isDenied: false, typed: "noe", caretAtEnd: true)
        )
    }

    func testNoOpinionMeansNoCandidates() {
        // The actual defect: the candidate list used to fall back to the whole
        // vault, which is what made it fire anywhere at all.
        let candidates = SuggestionPolicy.candidates(
            learned: nil,
            ranked: [],
            allowed: ["given_name", "email_personal", "phone_mobile"]
        )
        XCTAssertTrue(candidates.isEmpty, "got \(candidates)")
    }

    func testARememberedAnswerLeadsTheCandidates() {
        let candidates = SuggestionPolicy.candidates(
            learned: "email_school",
            ranked: [ScoredKey(key: "email_personal", score: 0.7)],
            allowed: ["email_school", "email_personal"]
        )
        XCTAssertEqual(candidates, ["email_school", "email_personal"])
    }

    func testCandidatesAreRestrictedToWhatIsActuallyAvailable() {
        let candidates = SuggestionPolicy.candidates(
            learned: "card_number",
            ranked: [ScoredKey(key: "email_personal", score: 0.7)],
            allowed: ["email_personal"]
        )
        XCTAssertEqual(candidates, ["email_personal"], "sensitive and empty keys must not be offered")
    }
}
