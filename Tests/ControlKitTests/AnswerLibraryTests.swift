import XCTest
@testable import ControlKit

/// Reusing answers: when a question counts as asked before, and what Jev sees.
final class AnswerLibraryTests: XCTestCase {
    private let funFact = SavedAnswer(questions: ["What's a fun fact about you?"],
                                      text: "I can solve a Rubik's cube in under a minute.", site: "docs.google.com")
    private let whyUs = SavedAnswer(questions: ["Why do you want to work at Example?"],
                                    text: "Because of the evals team.", site: "boards.greenhouse.io")

    private func box(_ label: String, role: String = "AXTextArea", nearby: [String] = []) -> FieldContext {
        FieldContext(appName: "Chrome", bundleID: "com.google.Chrome", domain: "jobs.lever.co", role: role,
                     label: label, nearbyText: nearby)
    }

    // MARK: The same question

    func testTheSameWordingMatchesLocally() {
        for wording in ["What's a fun fact about you?", "whats a fun fact about you", "What's a fun fact about you? Required question"] {
            XCTAssertEqual(AnswerLibrary.exactMatch(for: wording, in: [whyUs, funFact])?.id, funFact.id, wording)
        }
        XCTAssertNil(AnswerLibrary.exactMatch(for: "Tell us a fun fact", in: [funFact]), "rewording is Jev's call")
    }

    func testCandidatesPutTheLikeliestFirstAndAreCapped() {
        let many = (0 ..< 20).map { SavedAnswer(questions: ["Unrelated question \($0)"], text: "x", site: nil) }
        let ranked = AnswerLibrary.candidates(for: "Tell us a fun fact about yourself", in: many + [funFact])
        XCTAssertEqual(ranked.first?.id, funFact.id)
        XCTAssertEqual(ranked.count, AnswerLibrary.maxCandidates)
    }

    // MARK: Whether it fits this box

    func testASavedAnswerOverTheLimitIsntReused() {
        let long = SavedAnswer(questions: ["Q"], text: String(repeating: "word ", count: 300), site: nil)
        XCTAssertFalse(AnswerLibrary.fits(long.text, in: box("Why us? (250 words)")))
        XCTAssertTrue(AnswerLibrary.fits(funFact.text, in: box("Why us? (250 words)")))
    }

    func testParagraphsDontGoInASingleLine() {
        XCTAssertFalse(AnswerLibrary.fits("One.\n\nTwo.", in: box("Fun fact?", role: "AXTextField")))
        XCTAssertTrue(AnswerLibrary.fits(funFact.text, in: box("Fun fact?", role: "AXTextField")))
    }

    // MARK: Jev

    func testJevSeesQuestionsNeverAnswers() throws {
        let questions = AnswerReuse.questions(for: [funFact, whyUs])
        let body = String(decoding: try JSONEncoder().encode(questions), as: UTF8.self)
        XCTAssertTrue(body.contains("What's a fun fact about you?"))
        XCTAssertTrue(body.contains(funFact.id.uuidString))
        XCTAssertTrue(body.contains(JevMatcher.noMatchKey))
        XCTAssertFalse(body.contains("Rubik"), "an answer never goes to Jev")
        XCTAssertFalse(body.contains("evals team"))

        let state = String(decoding: try JSONEncoder().encode(AnswerReuse.state(question: "Tell us a fun fact", site: "jobs.lever.co")),
                           as: UTF8.self)
        XCTAssertTrue(state.contains("Tell us a fun fact"))
    }

    func testOnlyAConfidentPickIsReused() {
        let key = AnswerReuse.questionKey
        let confident = [key: JevAnswer(choice: funFact.id.uuidString, confidence: 0.9)]
        let unsure = [key: JevAnswer(choice: funFact.id.uuidString, confidence: 0.6)]
        let none = [key: JevAnswer(choice: JevMatcher.noMatchKey, confidence: 0.95)]
        XCTAssertEqual(AnswerReuse.pick(confident, from: [funFact, whyUs])?.id, funFact.id)
        XCTAssertNil(AnswerReuse.pick(unsure, from: [funFact, whyUs]))
        XCTAssertNil(AnswerReuse.pick(none, from: [funFact, whyUs]))
        XCTAssertNil(AnswerReuse.pick([key: JevAnswer(choice: UUID().uuidString, confidence: 0.99)], from: [funFact]),
                     "a choice that isn't one of the candidates")
    }
}

/// Saved answers are stored like "About you", against the real Keychain under a
/// throwaway service name.
@MainActor
final class SavedAnswerStorageTests: XCTestCase {
    private let settings = "com.noelsason.Control.tests.saved"
    private var suiteName = ""
    private var preferences: Preferences!

    override func setUp() async throws {
        try Keychain.deleteAll(service: settings)
        suiteName = "control-tests-\(UUID().uuidString)"
        preferences = Preferences(defaults: UserDefaults(suiteName: suiteName)!,
                                  settingsService: settings, legacyKeyService: settings + ".legacy")
    }

    override func tearDown() async throws {
        try Keychain.deleteAll(service: settings)
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func testReuseIsOnByDefault() {
        XCTAssertTrue(preferences.reuseAnswers)
    }

    func testTheEditedVersionReplacesTheDraftAndNewWordingsAreKept() {
        let id = UUID()
        preferences.saveAnswer(id: id, question: "What's a fun fact about you?", text: "Draft text.", site: "a.com")
        preferences.saveAnswer(id: id, question: "What's a fun fact about you?", text: "  My edited text.  ", site: "a.com")
        preferences.saveAnswer(id: id, question: "Tell us something surprising", text: "My edited text.", site: "b.com")

        let saved = preferences.savedAnswers
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].text, "My edited text.")
        XCTAssertEqual(saved[0].questions, ["What's a fun fact about you?", "Tell us something surprising"])
    }

    func testAnEmptyAnswerIsntSaved() {
        preferences.saveAnswer(id: UUID(), question: "Q", text: "   ", site: nil)
        XCTAssertEqual(preferences.savedAnswers, [])
    }

    func testTheLeastRecentlyUsedGoFirst() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        for index in 0 ..< Preferences.maxSavedAnswers + 3 {
            preferences.saveAnswer(id: UUID(), question: "Q\(index)", text: "A\(index)", site: nil,
                                   at: start.addingTimeInterval(Double(index)))
        }
        let saved = preferences.savedAnswers
        XCTAssertEqual(saved.count, Preferences.maxSavedAnswers)
        XCTAssertFalse(saved.contains { $0.text == "A0" })
        XCTAssertTrue(saved.contains { $0.text == "A\(Preferences.maxSavedAnswers + 2)" })
    }
}
