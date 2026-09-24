import XCTest
@testable import ControlKit

/// Long-answer drafting: which fields qualify, what the request carries, and
/// how replies are read — against recorded JSON, no network.
final class AnswerDraftingTests: XCTestCase {
    private func field(
        _ label: String?,
        role: String = "AXTextArea",
        placeholder: String? = nil,
        helpText: String? = nil,
        nearby: [String] = [],
        heading: String? = nil,
        isEmpty: Bool = true
    ) -> FieldContext {
        FieldContext(
            appName: "Google Chrome",
            bundleID: "com.google.Chrome",
            domain: "boards.greenhouse.io",
            role: role,
            label: label,
            placeholder: placeholder,
            helpText: helpText,
            nearbyText: nearby,
            isEmpty: isEmpty,
            heading: heading
        )
    }

    // MARK: Which fields are open-ended questions

    func testEssayPromptsQualify() {
        for label in [
            "Tell us about a technical project you're proud of.",
            "Why Anthropic?",
            "Describe your research interests (250 words)",
            "Please explain how you would approach this problem",
            "Anything else you'd like us to know?",
            "In 150 words or fewer, share something you've built",
        ] {
            XCTAssertTrue(LongAnswerPolicy.isOpenEndedQuestion(field(label)), label)
        }
    }

    func testOrdinaryMultiLineFieldsDoNot() {
        for label in ["Cover letter", "Additional comments", "Message", "Address", "Write your prompt to Claude"] {
            XCTAssertFalse(LongAnswerPolicy.isOpenEndedQuestion(field(label)), label)
        }
    }

    func testASingleLineQuestionWantsAShortAnswer() {
        XCTAssertFalse(LongAnswerPolicy.isOpenEndedQuestion(field("How did you hear about us?", role: "AXTextField")))
    }

    func testAQuestionOnlyInThePlaceholderIsAChatBox() {
        XCTAssertFalse(LongAnswerPolicy.isOpenEndedQuestion(field(nil, placeholder: "What's on your mind?")))
        XCTAssertFalse(LongAnswerPolicy.isOpenEndedQuestion(field("Message", placeholder: "How can I help you today?")))
    }

    func testAFieldWithTextInItIsLeftAlone() {
        XCTAssertFalse(LongAnswerPolicy.isOpenEndedQuestion(field("Why Anthropic?", isEmpty: false)))
    }

    func testTheLabelCellCountsAsTheQuestion() {
        let question = "What are you hoping to learn in this role?"
        let context = field(nil, nearby: [question, "Application questions"], heading: question)
        XCTAssertEqual(LongAnswerPolicy.question(in: context), question)
        XCTAssertTrue(LongAnswerPolicy.isOpenEndedQuestion(context))
    }

    // MARK: What the request carries

    func testTheRequestCarriesTheQuestionAndPageButNotTheDOMID() {
        var context = field(
            "Why do you want to work here?",
            placeholder: "Type your answer",
            helpText: "Max 1000 characters",
            nearby: ["Question 3 of 5"]
        )
        context.domIdentifier = "question_28172637"

        let message = AnswerDrafter.request(for: context, pageTitle: "Job Application for Research Engineer at Example")

        XCTAssertTrue(message.contains("<question>\nWhy do you want to work here?\n</question>"))
        XCTAssertTrue(message.contains("Help text: Max 1000 characters"), "the length limit has to reach the model")
        XCTAssertTrue(message.contains("Placeholder: Type your answer"))
        XCTAssertTrue(message.contains("- Question 3 of 5"))
        XCTAssertTrue(message.contains("Title: Job Application for Research Engineer at Example"))
        XCTAssertTrue(message.contains("Site: boards.greenhouse.io"))
        XCTAssertFalse(message.contains("Label:"), "the label is the question; saying it twice adds nothing")
        XCTAssertFalse(message.contains("question_28172637"))
    }

    func testAHandPickedDraftForAnUnlabelledBoxUsesTheTextAboveIt() {
        let message = AnswerDrafter.request(for: field(nil, nearby: ["Your biggest failure"], heading: "Your biggest failure"),
                                            pageTitle: nil)
        XCTAssertTrue(message.contains("<question>\nYour biggest failure\n</question>"))
    }

    func testASingleLineBoxAsksForAShortAnswer() {
        let short = AnswerDrafter.request(for: field("Why this team?", role: "AXTextField"), pageTitle: nil)
        let long = AnswerDrafter.request(for: field("Why this team?"), pageTitle: nil)
        XCTAssertTrue(short.contains("one or two sentences"))
        XCTAssertFalse(long.contains("one or two sentences"))
    }

    func testNearbyTextIsCappedLikeJevs() {
        let nearby = (0 ..< 20).map { "Line \($0) " + String(repeating: "x", count: 300) }
        let message = AnswerDrafter.request(for: field("Why us?", nearby: nearby), pageTitle: nil)
        let lines = message.split(separator: "\n").filter { $0.hasPrefix("- Line") }
        XCTAssertEqual(lines.count, AnswerDrafter.maxNearbyText)
        XCTAssertTrue(lines.allSatisfy { $0.count <= AnswerDrafter.maxNearbyTextLength + 2 })
    }

    func testTheProfileIsTheCachedBlock() throws {
        let body = try ClaudeClient.encode(ClaudeRequest(
            model: ClaudeClient.defaultModel,
            max_tokens: AnswerDrafter.maxTokens,
            thinking: .init(),
            output_config: .init(effort: AnswerDrafter.effort),
            system: [
                .init(text: AnswerDrafter.instructions, cache_control: nil),
                .init(text: AnswerDrafter.profile("  I build things.  "), cache_control: .init()),
            ],
            messages: [.init(role: "user", content: "Why us?")]
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let system = try XCTUnwrap(json["system"] as? [[String: Any]])

        XCTAssertEqual(json["model"] as? String, "claude-sonnet-5")
        XCTAssertEqual((json["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertEqual((json["output_config"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertNil(system[0]["cache_control"])
        XCTAssertEqual((system[1]["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")
        XCTAssertEqual(system[1]["text"] as? String, "<about_me>\nI build things.\n</about_me>")
    }

    func testTheRequestAsksForAStream() throws {
        let body = try ClaudeClient.encode(ClaudeRequest(
            model: ClaudeClient.defaultModel, max_tokens: 10, thinking: .init(),
            output_config: .init(effort: "low"), system: [], messages: []
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    // MARK: Reading the stream

    /// A recorded stream, trimmed: thinking first (empty, as it arrives by
    /// default), then text in fragments, then the stop reason.
    private let recorded = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5","stop_reason":null,"usage":{"input_tokens":12,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}

    event: ping
    data: {"type":"ping"}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"I built a pipe"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"line.\\n\\nIt worked."}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":40}}

    event: message_stop
    data: {"type":"message_stop"}
    """

    private func run(_ stream: String) throws -> String {
        var parser = ClaudeStreamParser()
        var text = ""
        for line in stream.split(separator: "\n", omittingEmptySubsequences: false) {
            if let piece = try parser.consume(String(line)) { text += piece }
        }
        try parser.finish()
        return text
    }

    func testTextDeltasAreYieldedAndEverythingElseSkipped() throws {
        XCTAssertEqual(try run(recorded), "I built a pipeline.\n\nIt worked.")
    }

    func testUsageIsReadFromTheStartAndTheEnd() throws {
        let stream = recorded.replacingOccurrences(
            of: #""usage":{"input_tokens":12,"output_tokens":1}"#,
            with: #""usage":{"input_tokens":12,"cache_creation_input_tokens":0,"cache_read_input_tokens":4800,"output_tokens":1}"#
        )
        var parser = ClaudeStreamParser()
        for line in stream.split(separator: "\n") { _ = try parser.consume(String(line)) }
        XCTAssertEqual(parser.usage, ClaudeUsage(inputTokens: 12, cacheWriteTokens: 0, cacheReadTokens: 4800, outputTokens: 40))
    }

    func testCostIsEstimatedFromListPrices() {
        // Sonnet 5: $2 in, $10 out per million. A cache read is a tenth of input.
        let usage = ClaudeUsage(inputTokens: 1000, cacheWriteTokens: 0, cacheReadTokens: 5000, outputTokens: 400)
        let expected: Double = (2000 + 1000 + 4000) / 1_000_000  // input, cache reads, output
        XCTAssertEqual(usage.dollars(for: "claude-sonnet-5"), expected, accuracy: 1e-12)
        XCTAssertEqual(ClaudeUsage(cacheWriteTokens: 1_000_000).dollars(for: "claude-haiku-4-5"), 1.25, accuracy: 1e-9)
        XCTAssertEqual(usage.dollars(for: "some-other-model"), 0)
    }

    func testARefusalEndsTheStreamWithAnError() {
        let stream = recorded.replacingOccurrences(of: #""stop_reason":"end_turn""#, with: #""stop_reason":"refusal""#)
        XCTAssertThrowsError(try run(stream)) { XCTAssertEqual($0 as? ClaudeError, .refused) }
    }

    func testTheTokenCapEndsTheStreamWithAnError() {
        let stream = recorded.replacingOccurrences(of: #""stop_reason":"end_turn""#, with: #""stop_reason":"max_tokens""#)
        XCTAssertThrowsError(try run(stream)) { XCTAssertEqual($0 as? ClaudeError, .truncated) }
    }

    func testAStreamThatStopsWithoutAReasonIsIncomplete() {
        let cut = recorded.components(separatedBy: "event: message_delta")[0]
        XCTAssertThrowsError(try run(cut)) { XCTAssertEqual($0 as? ClaudeError, .incomplete) }
    }

    func testAnErrorEventMidStreamIsReported() {
        var parser = ClaudeStreamParser()
        let overloaded = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        XCTAssertThrowsError(try parser.consume(overloaded)) { XCTAssertEqual($0 as? ClaudeError, .http(529)) }

        let other = #"data: {"type":"error","error":{"type":"api_error","message":"Something broke."}}"#
        XCTAssertThrowsError(try parser.consume(other)) {
            XCTAssertEqual($0 as? ClaudeError, .api(status: 200, message: "Something broke."))
        }
    }

    func testAFailedRequestCarriesTheServicesOwnWords() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"Bad model."}}"#.utf8)
        XCTAssertEqual(ClaudeClient.error(status: 400, body: body), .api(status: 400, message: "Bad model."))
    }

    func testABadKeyUsesControlsWording() {
        let body = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        XCTAssertEqual(ClaudeClient.error(status: 401, body: body), .http(401))
    }

    // MARK: Pieces for the field

    private func chunk(_ deltas: [String]) -> [String] {
        var chunker = DraftChunker()
        var out = deltas.map { chunker.feed($0) }
        out.append(chunker.finish())
        return out.filter { !$0.isEmpty }
    }

    func testPiecesAreWholeWords() {
        XCTAssertEqual(chunk(["I bu", "ilt a pipe", "line. It ", "worked."]),
                       ["I", " built a", " pipeline. It", " worked."])
    }

    func testTheAnswersOwnLeadingAndTrailingWhitespaceIsDropped() {
        XCTAssertEqual(chunk(["\n\n  ", "Hello", " there.\n"]), ["Hello there."])
    }

    func testParagraphBreaksSurvive() {
        XCTAssertEqual(chunk(["First.\n", "\nSecond."]).joined(), "First.\n\nSecond.")
    }

    func testEmDashesNeverReachTheField() {
        XCTAssertEqual(chunk(["I built Scope \u{2014} a search tool."]).joined(), "I built Scope, a search tool.")
        XCTAssertEqual(chunk(["It worked\u{2014}mostly."]).joined(), "It worked, mostly.")
    }

    func testAnEmDashSplitAcrossPiecesIsSpacedOnce() {
        XCTAssertEqual(chunk(["I built it ", "\u{2014}", " and ", "shipped it."]).joined(), "I built it, and shipped it.")
        XCTAssertEqual(chunk(["word\u{2014}", "next one."]).joined(), "word, next one.")
        XCTAssertEqual(chunk(["It ends \u{2014}"]).joined(), "It ends")
        XCTAssertFalse(chunk(["a \u{2014}", " b \u{2014} c\u{2014}d"]).joined().contains("\u{2014}"))
    }

    func testThePromptAsksForNoEmDashesAndUsesNone() {
        XCTAssertTrue(AnswerDrafter.instructions.contains("Never use em dashes"))
        XCTAssertFalse(AnswerDrafter.instructions.contains("\u{2014}"), "models echo the punctuation they're shown")
        XCTAssertFalse(AnswerDrafter.instructions.contains(";"))
    }

    func testAllWhitespaceYieldsNothing() {
        XCTAssertEqual(chunk([" ", "\n"]), [])
    }

    // MARK: Whether the field still holds the draft

    func testTheDraftIsIntactUntilTheUserChangesIt() {
        XCTAssertTrue(InsertionPlan.draftIsIntact(inserted: "", current: ""))
        XCTAssertTrue(InsertionPlan.draftIsIntact(inserted: "I built", current: "I built"))
        XCTAssertTrue(InsertionPlan.draftIsIntact(inserted: "One.\n\nTwo", current: "One.\nTwo"),
                      "editors report line breaks differently")
        XCTAssertTrue(InsertionPlan.draftIsIntact(inserted: "I built", current: nil))
        XCTAssertFalse(InsertionPlan.draftIsIntact(inserted: "I built", current: "I builtx"))
        XCTAssertFalse(InsertionPlan.draftIsIntact(inserted: "", current: "a"), "the user got there first")
    }
}

/// One sitting at one form: later drafts see earlier ones, and limits are checked.
final class DraftHistoryTests: XCTestCase {
    private func entry(_ field: String, site: String = "boards.greenhouse.io", at: Date = Date()) -> DraftHistory.Entry {
        DraftHistory.Entry(question: "Q \(field)", text: "Answer \(field)", site: site, field: field, at: at)
    }

    func testOtherAnswersAreFromThisSiteAndOtherBoxesNewestFirst() {
        var history = DraftHistory()
        history.record(entry("a"))
        history.record(entry("b"))
        history.record(entry("x", site: "jobs.lever.co"))
        XCTAssertEqual(history.others(on: "boards.greenhouse.io", excluding: "c").map(\.field), ["b", "a"])
        XCTAssertEqual(history.others(on: "boards.greenhouse.io", excluding: "a").map(\.field), ["b"],
                       "the box being drafted isn't its own other answer")
    }

    func testANewDraftForTheSameBoxReplacesTheOld() {
        var history = DraftHistory()
        history.record(entry("a"))
        history.record(DraftHistory.Entry(question: "Q a", text: "Second try", site: "boards.greenhouse.io", field: "a"))
        XCTAssertEqual(history.entries.map(\.text), ["Second try"])
    }

    func testOldDraftsAgeOut() {
        var history = DraftHistory()
        history.record(entry("a", at: Date().addingTimeInterval(-3 * 60 * 60)))
        XCTAssertEqual(history.others(on: "boards.greenhouse.io", excluding: "b"), [])
    }

    func testTheRequestCarriesOtherAnswersAndTheDraftPassedOn() {
        let context = FieldContext(appName: "Chrome", bundleID: "com.google.Chrome", domain: "boards.greenhouse.io",
                                   role: "AXTextArea", label: "Why this team?")
        let message = AnswerDrafter.request(for: context, pageTitle: nil,
                                            otherAnswers: [entry("a")], previousDraft: "I built Scope.")
        XCTAssertTrue(message.contains("<other_answers_on_this_form>\nQuestion: Q a\nAnswer: Answer a\n</other_answers_on_this_form>"))
        XCTAssertTrue(message.contains("<draft_they_passed_on>\nI built Scope.\n</draft_they_passed_on>"))
        XCTAssertFalse(AnswerDrafter.request(for: context, pageTitle: nil).contains("other_answers_on_this_form"))
    }

    func testThePageExcerptGoesInCapped() {
        let context = FieldContext(appName: "Chrome", bundleID: "com.google.Chrome", domain: "boards.greenhouse.io",
                                   role: "AXTextArea", label: "Why this role?")
        let long = String(repeating: "a", count: AnswerDrafter.maxPageTextLength + 500)
        let message = AnswerDrafter.request(for: context, pageTitle: nil, pageText: "Research Engineer, Evals. " + long)
        XCTAssertTrue(message.contains("<page_text>\nResearch Engineer, Evals. "))
        let excerpt = message.components(separatedBy: "<page_text>\n")[1].components(separatedBy: "\n</page_text>")[0]
        XCTAssertEqual(excerpt.count, AnswerDrafter.maxPageTextLength)
    }

    // MARK: Length limits

    func testLimitsAreReadFromTheQuestion() {
        XCTAssertEqual(LengthLimit.parse("Describe a project (250 words max)"), LengthLimit(value: 250, unit: .words))
        XCTAssertEqual(LengthLimit.parse("Maximum 1,000 characters"), LengthLimit(value: 1000, unit: .characters))
        XCTAssertEqual(LengthLimit.parse("In 150-200 words, tell us why"), LengthLimit(value: 200, unit: .words),
                       "a range is met at its upper bound")
        XCTAssertEqual(LengthLimit.parse("500 character limit"), LengthLimit(value: 500, unit: .characters))
        XCTAssertNil(LengthLimit.parse("Write at least 100 words"), "a minimum is no limit")
        XCTAssertNil(LengthLimit.parse("Tell us about yourself"))
    }

    func testTheLimitCanComeFromHelpTextOrNearbyText() {
        let context = FieldContext(appName: "Chrome", bundleID: "com.google.Chrome", role: "AXTextArea",
                                   label: "Why us?", nearbyText: ["Please keep it under 300 words."])
        XCTAssertEqual(LengthLimit.find(in: context), LengthLimit(value: 300, unit: .words))
    }

    func testOverTheLimitIsCounted() {
        let limit = LengthLimit(value: 3, unit: .words)
        XCTAssertFalse(limit.isExceeded(by: "One two three"))
        XCTAssertTrue(limit.isExceeded(by: "One two three four"))
        XCTAssertTrue(LengthLimit(value: 5, unit: .characters).isExceeded(by: "Sixsix"))
    }
}

/// Drafting only turns on once everything it needs is saved, against the real
/// Keychain under a throwaway service name.
@MainActor
final class DraftSettingsTests: XCTestCase {
    private let settings = "com.noelsason.Control.tests.draft"
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

    func testDraftingNeedsTheKeyTheProfileAndTheSwitch() {
        XCTAssertTrue(preferences.draftAnswersEnabled, "on by default; it still needs a key and a profile")
        XCTAssertFalse(preferences.canDraftAnswers)

        preferences.claudeAPIKey = "sk-test"
        XCTAssertFalse(preferences.canDraftAnswers)

        preferences.aboutYou = "I build things."
        XCTAssertTrue(preferences.canDraftAnswers)

        preferences.draftAnswersEnabled = false
        XCTAssertFalse(preferences.canDraftAnswers)
    }

    func testUseIsTalliedByMonth() {
        let september = DateComponents(calendar: .current, year: 2026, month: 9, day: 20).date!
        let october = DateComponents(calendar: .current, year: 2026, month: 10, day: 2).date!
        preferences.recordUsage(.draft, dollars: 0.015, on: september)
        preferences.recordUsage(.draft, dollars: 0.02, on: september)
        preferences.recordUsage(.answerCheck, dollars: 0.001, on: september)
        preferences.recordUsage(.draft, dollars: 0.01, on: october)

        let usage = preferences.usage(in: september)
        XCTAssertEqual(usage.drafts, 2)
        XCTAssertEqual(usage.answersChecked, 1)
        XCTAssertEqual(usage.dollars, 0.036, accuracy: 1e-9)
        XCTAssertEqual(preferences.usage(in: october).drafts, 1)
    }

    func testClearingTheProfileRemovesIt() {
        preferences.aboutYou = "I build things."
        XCTAssertTrue(preferences.hasAboutYou)
        preferences.aboutYou = "   "
        XCTAssertFalse(preferences.hasAboutYou)
        XCTAssertEqual(preferences.aboutYou, "")
    }
}
