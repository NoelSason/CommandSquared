import AppKit
import ApplicationServices
import ControlKit
import Foundation

/// Notices when the user has finished answering a question on a form. Two
/// things follow: a box Control drafted into has its final text saved, edits
/// and all, for the next time the question comes up; and, when learning is on,
/// `AnswerLearner` is asked whether the answer says anything worth remembering.
///
/// It only reads; it never writes to a field. It waits until the user has
/// moved on — typed into another field, clicked away, switched apps, or left
/// the field alone for a while — so a half-written answer isn't judged. And
/// everything that may not be sent is ruled out before anything is:
/// `AnswerLearner.shouldConsider`, the denylist, saved details, and drafts
/// Control wrote itself.
@MainActor
final class AnswerWatcher {
    private struct Watched {
        let element: AXUIElement
        let context: FieldContext
        var value: String
        /// Set for a box holding a draft: its final text is saved under this.
        var savedAnswer: UUID?
    }

    /// Boxes Control drafted into, newest last, so coming back to one and
    /// editing it still updates what's saved.
    private var drafted: [(element: AXUIElement, context: FieldContext, savedAnswer: UUID)] = []
    private static let maxDrafted = 20

    /// A pause this long in typing means look at the field.
    private static let typingPause: Duration = .milliseconds(900)
    /// Left alone this long, a field counts as finished without moving on.
    private static let settledAfter: Duration = .seconds(20)
    /// A ceiling, in case something fires far more than typing could.
    private static let maxCallsPerHour = 40

    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?
    private var pauseTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?

    private var watched: Watched?
    /// The last field looked at and found not to be a question, so it isn't
    /// read again on every pause.
    private var ignored: AXUIElement?
    /// Every answer already judged this session, by field and text.
    private var judged: Set<String> = []
    private var recentCalls: [Date] = []

    private let vault: VaultStore
    private let preferences: Preferences
    private let isOwnDraft: @MainActor (String) -> Bool
    private let toast = ToastPresenter()

    init(vault: VaultStore, preferences: Preferences, isOwnDraft: @escaping @MainActor (String) -> Bool) {
        self.vault = vault
        self.preferences = preferences
        self.isOwnDraft = isOwnDraft
    }

    // MARK: Lifecycle

    /// Always running; every event checks the setting first, so turning it on
    /// or off in settings takes effect at once.
    func start() {
        stop()
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.typed() }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.clicked() }
        }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    func stop() {
        for monitor in [keyMonitor, mouseMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        mouseMonitor = nil
        if let appSwitchObserver { NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver) }
        appSwitchObserver = nil
        pauseTask?.cancel()
        settleTask?.cancel()
        watched = nil
        ignored = nil
    }

    // MARK: Watching

    /// A draft just went into this box. Watch it whatever the learning setting,
    /// so what the user finally leaves there is saved.
    func watchDraft(_ element: AXUIElement, context: FieldContext, savedAnswer: UUID, text: String) {
        if let watched, !AX.same(watched.element, element) { finish() }
        drafted.removeAll { AX.same($0.element, element) }
        drafted.append((element, context, savedAnswer))
        if drafted.count > Self.maxDrafted { drafted.removeFirst(drafted.count - Self.maxDrafted) }
        ignored = nil
        watched = Watched(element: element, context: context, value: text, savedAnswer: savedAnswer)
        waitForItToSettle()
    }

    private func typed() {
        guard preferences.learnFromAnswers || !drafted.isEmpty else { return }
        pauseTask?.cancel()
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.typingPause)
            guard !Task.isCancelled else { return }
            self?.look()
        }
    }

    /// A click may have moved focus. Give it a moment to land, then look.
    private func clicked() {
        guard watched != nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.look()
        }
    }

    /// Reads the focused field. Focus on anything other than the watched field
    /// means the watched one is finished.
    private func look() {
        guard AX.isTrusted, !NSRunningApplication.current.isActive else { return }
        let focused = AX.element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)

        if let watched, !(focused.map { AX.same($0, watched.element) } ?? false) {
            finish()
        }
        guard let focused else { return }
        let value = AX.rawValue(focused, kAXValueAttribute) ?? ""

        if var current = watched {
            if current.value != value {
                current.value = value
                watched = current
                waitForItToSettle()
            }
            return
        }
        if let entry = drafted.last(where: { AX.same($0.element, focused) }) {
            watched = Watched(element: focused, context: entry.context, value: value, savedAnswer: entry.savedAnswer)
            waitForItToSettle()
            return
        }
        guard preferences.learnFromAnswers else { return }
        if let ignored, AX.same(ignored, focused) { return }

        // A new field: read it once, and keep it only if it asks a question.
        guard let app = NSWorkspace.shared.frontmostApplication,
              case let .success(field) = AXFieldReader.read(focused, app: app),
              LongAnswerPolicy.question(in: field.context) != nil,
              !field.context.isSecureField
        else {
            ignored = focused
            return
        }
        ignored = nil
        watched = Watched(element: focused, context: field.context, value: value)
        waitForItToSettle()
    }

    private func waitForItToSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settledAfter)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    // MARK: Judging

    /// The watched field is done. Its answer is judged at most once.
    private func finish() {
        settleTask?.cancel()
        guard let watched else { return }
        self.watched = nil

        // One last live read. A page that has moved on keeps the last value seen.
        let answer = AX.rawValue(watched.element, kAXValueAttribute) ?? watched.value

        // A draft, as the user left it, is the answer to reuse next time.
        if let savedAnswer = watched.savedAnswer,
           !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preferences.saveAnswer(id: savedAnswer, question: FillController.question(of: watched.context),
                                   text: answer, site: watched.context.domain)
        }

        let key = watched.context.signature + "\u{1F}" + FieldContext.normalize(answer)

        guard preferences.canLearnFromAnswers,
              !preferences.isDenied(watched.context),
              AnswerLearner.shouldConsider(watched.context, answer: answer),
              !isOwnDraft(answer),
              !isASavedDetail(answer, context: watched.context),
              !judged.contains(key),
              withinBudget()
        else { return }
        judged.insert(key)

        Task { await learn(from: watched.context, answer: answer) }
    }

    private func learn(from context: FieldContext, answer: String) async {
        let preferences = self.preferences
        let learner = AnswerLearner(apiKey: preferences.claudeAPIKey) { usage in
            Task { @MainActor in
                preferences.recordUsage(.answerCheck, dollars: usage.dollars(for: AnswerLearner.model))
            }
        }
        let found: [String]
        do {
            found = try await learner.learn(
                from: context,
                answer: answer,
                aboutYou: preferences.aboutYou,
                known: preferences.learnedFacts.map(\.text)
            )
        } catch {
            Log.match.error("Couldn't judge an answer: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !found.isEmpty else {
            Log.match.info("Nothing worth remembering in an answer.")
            return
        }

        // Read again after the wait: another answer may have been learned meanwhile.
        let question = LongAnswerPolicy.question(in: context) ?? context.label ?? ""
        preferences.learnedFacts += found.map { LearnedFact(text: $0, question: question, site: context.domain) }
        Log.match.info("Learned \(found.count) fact(s) from an answer.")
        toast.show(title: "Noted for later", detail: found[0], symbol: "brain", tone: .success, near: nil,
                   footnote: found.count > 1 ? "and \(found.count - 1) more, in Control's settings" : nil)
    }

    /// An answer that is already a saved detail teaches nothing new.
    private func isASavedDetail(_ answer: String, context: FieldContext) -> Bool {
        let needle = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return vault.fillableFields.contains { field in
            guard !field.sensitive,
                  let value = try? vault.resolvedValue(for: field.key, context: context)
            else { return false }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
    }

    private func withinBudget() -> Bool {
        let hourAgo = Date().addingTimeInterval(-3600)
        recentCalls.removeAll { $0 < hourAgo }
        guard recentCalls.count < Self.maxCallsPerHour else {
            Log.match.error("Skipped judging an answer: over \(Self.maxCallsPerHour) this hour.")
            return false
        }
        recentCalls.append(Date())
        return true
    }
}
