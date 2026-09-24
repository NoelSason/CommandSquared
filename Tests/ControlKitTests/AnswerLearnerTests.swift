import XCTest
@testable import ControlKit

/// Learning from answers: above all, what may never be sent.
final class AnswerLearnerTests: XCTestCase {
    private func field(_ label: String?, role: String = "AXTextField", secure: Bool = false, heading: String? = nil) -> FieldContext {
        FieldContext(
            appName: "Google Chrome",
            bundleID: "com.google.Chrome",
            domain: "docs.google.com",
            role: role,
            subrole: secure ? FieldContext.secureTextFieldSubrole : nil,
            label: label,
            nearbyText: heading.map { [$0] } ?? [],
            heading: heading
        )
    }

    // MARK: What may be sent

    func testAnAnswerToAQuestionAboutYouIsConsidered() {
        XCTAssertTrue(AnswerLearner.shouldConsider(field("What's a fun fact about you?"),
                                                   answer: "I can solve a Rubik's cube in under a minute."))
        XCTAssertTrue(AnswerLearner.shouldConsider(field("Where did you grow up Required question"),
                                                   answer: "Santa Clarita, California"))
        XCTAssertTrue(AnswerLearner.shouldConsider(field("Why are you interested in healthcare?", role: "AXTextArea"),
                                                   answer: "I spent a summer shadowing in a hospital."),
                      "healthcare is a subject, not the user's health")
    }

    func testFieldsThatArentQuestionsAreNeverRead() {
        for label in ["Message", "Comment", "Search", "Subject", "Notes"] {
            XCTAssertFalse(AnswerLearner.shouldConsider(field(label), answer: "Some words about something here"), label)
        }
        XCTAssertFalse(AnswerLearner.shouldConsider(field(nil), answer: "Some words about something here"))
    }

    func testPasswordFieldsAreNeverRead() {
        XCTAssertFalse(AnswerLearner.shouldConsider(field("What is your password?", secure: true), answer: "correct horse battery"))
    }

    func testDemographicLegalMoneyAndHealthQuestionsAreNeverSent() {
        for label in [
            "What is your gender?", "Are you a protected veteran?", "Do you have a disability?",
            "What is your race or ethnicity?", "Will you require visa sponsorship?", "What are your salary expectations?",
            "Have you ever been convicted of a crime?", "Do you have any health conditions we should know about?",
            "What was your mother's maiden name?", "What is your social security number?",
        ] {
            XCTAssertFalse(AnswerLearner.shouldConsider(field(label), answer: "A long enough answer to consider"), label)
        }
        XCTAssertFalse(AnswerLearner.shouldConsider(field("Please explain", heading: "Voluntary Self-Identification of Disability"),
                                                    answer: "A long enough answer to consider"),
                       "the section counts, as it does for addresses")
    }

    func testAnswersThatArentProseAreNeverSent() {
        let question = field("What is your portfolio link?")
        XCTAssertFalse(AnswerLearner.shouldConsider(question, answer: "https://example.com/portfolio"), "one token")
        XCTAssertFalse(AnswerLearner.shouldConsider(question, answer: "Yes"), "too short")
        XCTAssertFalse(AnswerLearner.shouldConsider(field("What is your student number?"), answer: "3036 123 456"), "mostly digits")
    }

    // MARK: The request

    func testTheRequestCarriesTheQuestionAnswerAndWhatsKnown() {
        let message = AnswerLearner.request(for: field("What's a fun fact about you?"),
                                            answer: "  I have a twin brother.  ",
                                            known: ["I grew up in Santa Clarita."])
        XCTAssertTrue(message.contains("<question>\nWhat's a fun fact about you?\n</question>"))
        XCTAssertTrue(message.contains("<answer>\nI have a twin brother.\n</answer>"))
        XCTAssertTrue(message.contains("I grew up in Santa Clarita."))
        XCTAssertTrue(message.contains("<site>docs.google.com</site>"))
    }

    func testTheRequestUsesHaikuWithoutThinkingOrEffort() throws {
        XCTAssertEqual(AnswerLearner.model, "claude-haiku-4-5")
        let body = try ClaudeClient.encode(ClaudeRequest(
            model: AnswerLearner.model, max_tokens: 400, thinking: nil, output_config: nil, system: [], messages: []
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["thinking"], "Haiku 4.5 takes no adaptive thinking")
        XCTAssertNil(json["output_config"], "and rejects an effort level")
    }

    func testThePromptUsesNoDashesOrSemicolons() {
        XCTAssertFalse(AnswerLearner.instructions.contains("\u{2014}"))
        XCTAssertFalse(AnswerLearner.instructions.contains(";"))
    }

    // MARK: The reply

    func testNoneMeansNothing() {
        XCTAssertEqual(AnswerLearner.parse("NONE"), [])
        XCTAssertEqual(AnswerLearner.parse("  none \n"), [])
        XCTAssertEqual(AnswerLearner.parse(""), [])
    }

    func testFactsComeOneALineTidiedAndCapped() {
        let reply = """
        - I have a twin brother.
        2. I can solve a Rubik's cube in under a minute.

        • I taught myself Swift.
        I play the tabla.
        """
        XCTAssertEqual(AnswerLearner.parse(reply), [
            "I have a twin brother.",
            "I can solve a Rubik's cube in under a minute.",
            "I taught myself Swift.",
        ])
    }

    // MARK: Drafts use what was learned

    func testLearnedFactsRideAlongWithTheProfile() {
        let learned = [LearnedFact(text: "I have a twin brother.", question: "Fun fact?", site: nil)]
        let profile = AnswerDrafter.profile("I build things.", learned: learned)
        XCTAssertTrue(profile.contains("<learned_from_my_answers>\n- I have a twin brother.\n</learned_from_my_answers>"))
        XCTAssertFalse(AnswerDrafter.profile("I build things.").contains("learned_from_my_answers"))
    }
}

/// Learned facts are stored like "About you", against the real Keychain under a
/// throwaway service name.
@MainActor
final class LearnedFactStorageTests: XCTestCase {
    private let settings = "com.noelsason.Control.tests.learned"
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

    func testLearningIsOffUntilTurnedOnAndNeedsDrafting() {
        XCTAssertFalse(preferences.learnFromAnswers, "it sends what the user typed, so it starts off")
        preferences.learnFromAnswers = true
        XCTAssertFalse(preferences.canLearnFromAnswers, "no key or profile yet")
        preferences.claudeAPIKey = "sk-test"
        preferences.aboutYou = "I build things."
        XCTAssertTrue(preferences.canLearnFromAnswers)
    }

    func testFactsRoundTripAndTheOldestGoFirst() {
        let facts = (0 ..< Preferences.maxLearnedFacts + 5).map {
            LearnedFact(text: "Fact \($0)", question: "Q", site: nil)
        }
        preferences.learnedFacts = facts
        let stored = preferences.learnedFacts
        XCTAssertEqual(stored.count, Preferences.maxLearnedFacts)
        XCTAssertEqual(stored.first?.text, "Fact 5")
        XCTAssertEqual(stored.last?.text, "Fact \(Preferences.maxLearnedFacts + 4)")

        preferences.learnedFacts = []
        XCTAssertEqual(preferences.learnedFacts, [])
    }
}
