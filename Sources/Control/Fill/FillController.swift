import AppKit
import ApplicationServices
import ControlKit
import Foundation

/// Everything that happens between the hotkey firing and text landing in a field.
@MainActor
final class FillController {
    let vault: VaultStore
    let cache: MatchCache
    let preferences: Preferences
    private let coordinator: MatchCoordinator

    private let toast = ToastPresenter()
    private let picker = PickerPresenter()
    private let corrections = CorrectionWatcher()
    /// Set by the app delegate. When a typed-ahead suggestion is on screen, the
    /// trigger cycles it instead of starting a fresh fill.
    weak var suggester: InlineSuggester?
    /// Set by the app delegate. Told about every draft, so the text the user
    /// finally leaves in the box is what gets saved.
    weak var answerWatcher: AnswerWatcher?

    /// When the inspector window is open the hotkey captures instead of filling,
    /// so the capture layer can be validated without anything being typed.
    var inspectorIsOpen = false
    var onInspect: (@MainActor (FieldContext, [(String, String)]) -> Void)?

    /// Set while setup's practice box has focus. Control's own window can't be
    /// read through the Accessibility API from Control itself — the request
    /// waits on the main thread that is making it — so the trigger is handed to
    /// setup instead, which fills its box through `practiceFill`.
    var practiceHandler: (@MainActor () async -> Bool)?

    private var lastFill: FillPlanner.LastFill?
    private var lastElement: AXUIElement?
    /// How long after a fill a second press means "wrong one, try the next"
    /// rather than "fill this again". Long enough to read the field and react.

    init(vault: VaultStore, cache: MatchCache, preferences: Preferences) {
        self.vault = vault
        self.cache = cache
        self.preferences = preferences
        coordinator = MatchCoordinator(vault: vault, cache: cache, preferences: preferences)
        vault.activeProfileID = preferences.activeProfileID
        corrections.onChange = { [weak self] value in
            self?.learnFromEdit(value)
        }
    }

    // MARK: Entry point

    func handleHotkey() async {
        // A press while a draft is being written stops it, wherever focus is.
        if let draftTask {
            draftStopRequested = true
            draftTask.cancel()
            return
        }
        guard !picker.isVisible else { return }
        if let practiceHandler, await practiceHandler() { return }
        // Control's own windows are not something to fill, and reading them
        // through the Accessibility API from Control itself can hang.
        guard !NSRunningApplication.current.isActive else { return }
        if await suggester?.acceptFromTrigger() == true { return }
        corrections.stop()

        guard AX.isTrusted else {
            toast.show(
                title: "Control needs Accessibility access",
                detail: "Open Control's settings to grant it.",
                symbol: "exclamationmark.triangle.fill",
                tone: .warning,
                near: nil
            )
            return
        }

        switch await AXFieldReader.readFocusedField() {
        case let .failure(reason):
            toast.show(title: reason.message, detail: "", symbol: "exclamationmark.circle", tone: .warning, near: nil)

        case let .success(field):
            if inspectorIsOpen {
                onInspect?(field.context, AXFieldReader.debugDump(field.element))
                return
            }
            if await redraftIfRepeat(field) { return }
            // Highlighted text containing {placeholders} is a template, and the
            // user is asking for it to be filled in — not for this field to be
            // matched against the vault.
            if await expandSelection(field) { return }
            if await cycleIfRepeat(field) { return }
            await fill(field)
        }
    }

    /// The trigger tapped three times: write an answer in this box, whatever
    /// it looks like. The same draft as a recognised question gets, minus the
    /// guessing — so it still needs drafting set up, an empty box, and a field
    /// Control is allowed to touch.
    func handleDraftHotkey() async {
        if let draftTask {
            draftStopRequested = true
            draftTask.cancel()
            return
        }
        guard !picker.isVisible, !NSRunningApplication.current.isActive else { return }
        corrections.stop()

        guard AX.isTrusted else {
            toast.show(title: "Control needs Accessibility access", detail: "Open Control's settings to grant it.",
                       symbol: "exclamationmark.triangle.fill", tone: .warning, near: nil)
            return
        }
        guard preferences.canDraftAnswers else {
            toast.show(title: "Long answers aren't set up", detail: "Add your details in Control's settings.",
                       symbol: "pencil.line", tone: .warning, near: nil)
            return
        }

        switch await AXFieldReader.readFocusedField() {
        case let .failure(reason):
            toast.show(title: reason.message, detail: "", symbol: "exclamationmark.circle", tone: .warning, near: nil)

        case let .success(field):
            let anchor = AX.frame(field.element)
            if field.context.isSecureField {
                toast.show(title: BlockReason.secureField.message, detail: "", symbol: "hand.raised.fill",
                           tone: .warning, near: anchor)
            } else if preferences.isDenied(field.context) {
                toast.show(title: BlockReason.deniedApp.message, detail: "", symbol: "hand.raised.fill",
                           tone: .warning, near: anchor)
            } else if !field.context.isEmpty {
                toast.show(title: "Clear the box first", detail: "A draft never goes on top of what's there.",
                           symbol: "pencil.line", tone: .warning, near: anchor)
            } else {
                await draftAnswer(field, anchor: anchor)
            }
        }
    }

    /// Switches to whichever profile this site last used.
    ///
    /// Silent on purpose: the profile is part of *where you are*, not a mode you
    /// hold in your head. Announcing every switch would be noise, and the picker
    /// labels any value that came from somewhere other than the active profile.
    private func adoptProfile(for context: FieldContext) {
        guard let learned = preferences.profile(for: context),
              learned != vault.activeProfileID
        else { return }

        vault.activeProfileID = learned
        preferences.activeProfileID = learned
        Log.match.info("Switched to the \(learned, privacy: .public) profile for this site.")
    }

    // MARK: Selection templates

    /// Expands `{placeholders}` in the highlighted text, in place.
    ///
    /// Type a draft with gaps — "Hi, I'm {full_name}, graduating {grad_year}" —
    /// select it, trigger, and the gaps close. Unrecognised placeholders are left
    /// standing rather than deleted, and the toast says which, because quietly
    /// removing something from text you are about to send is unforgivable.
    private func expandSelection(_ field: FocusedField) async -> Bool {
        guard let selection = AX.selectedText(field.element),
              TemplateEngine.containsPlaceholder(selection)
        else { return false }

        let result = TemplateEngine.expand(selection, in: environment(for: field.context))
        guard result.text != selection else { return false }

        await TextInserter.waitForModifierRelease()
        guard AX.replaceSelection(field.element, with: result.text, cursorOffset: result.cursorOffset)
        else {
            toast.show(title: "Couldn't replace the selection", detail: "", symbol: "xmark.circle",
                       tone: .warning, near: AX.frame(field.element))
            return true
        }

        let filled = (selection.count - result.unresolved.count)
        toast.show(
            title: result.isFullyResolved ? "Filled in" : "Filled in what I could",
            detail: result.isFullyResolved
                ? ""
                : "Left alone: " + result.unresolved.map { "{\($0)}" }.joined(separator: " "),
            symbol: result.isFullyResolved ? "checkmark.circle.fill" : "questionmark.circle",
            tone: result.isFullyResolved ? .success : .warning,
            near: AX.frame(field.element)
        )
        _ = filled
        Log.match.info("Expanded a selection template; \(result.unresolved.count) unresolved.")
        return true
    }

    /// Placeholders resolve against the vault by key *or* by label, so `{email}`
    /// works as well as `{email_personal}` — the user should not have to learn
    /// internal key names to write a snippet.
    private func environment(for context: FieldContext) -> TemplateEngine.Environment {
        TemplateEngine.Environment(
            clipboard: NSPasteboard.general.string(forType: .string),
            value: { [weak self] token in
                MainActor.assumeIsolated {
                    guard let self else { return nil }
                    let wanted = FieldContext.normalize(token)
                    let match = self.vault.fields.first { field in
                        field.key == token || FieldContext.normalize(field.label) == wanted
                    }
                    guard let match, !match.sensitive else { return nil }
                    // A token that can't be read is left as written, so the gap
                    // is visible in the text — and the reason is in the log.
                    do {
                        guard let value = try self.vault.resolvedValue(for: match.key, context: context),
                              !value.isEmpty
                        else { return nil }
                        return value
                    } catch {
                        Log.insert.error("Snippet token {\(token, privacy: .public)} could not be read: \(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                }
            }
        )
    }

    // MARK: Practice

    /// What a field with this label would be filled with: the real matcher and
    /// the real vault, without reading or writing any other app. Sensitive
    /// values are never used for practice.
    func practiceFill(label: String) async -> String? {
        let context = FieldContext(
            appName: "Control",
            bundleID: Bundle.main.bundleIdentifier ?? "Control",
            role: kAXTextFieldRole,
            label: label
        )
        let result: MatchResult
        switch await coordinator.decide(for: context) {
        case let .insert(match), let .confirm(match): result = match
        case .choose, .blocked, .draft: return nil
        }
        guard let field = vault.field(for: result.key), !field.sensitive else { return nil }
        do {
            return try vault.resolvedValue(for: result.key, context: context)
        } catch {
            Log.insert.error("Practice fill could not read \(result.key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Fill

    private func fill(_ field: FocusedField) async {
        adoptProfile(for: field.context)
        let anchor = AX.frame(field.element)
        let decision = await coordinator.decide(for: field.context)

        switch decision {
        case let .blocked(reason):
            toast.show(title: reason.message, detail: "", symbol: "hand.raised.fill", tone: .warning, near: anchor)

        case let .insert(result):
            // A Jev round trip is long enough for the user to have moved on.
            guard TextInserter.isStillFocused(field.element) else {
                toast.show(title: "Focus moved", detail: "Nothing was filled.", symbol: "arrow.uturn.left", tone: .warning, near: anchor)
                return
            }
            await perform(result.key, field: field, source: result.source, userConfirmed: false, ranked: FillPlanner.cycleList(for: result))

        case let .confirm(result):
            presentPicker(
                field: field,
                anchor: anchor,
                ranked: pickerList(startingWith: FillPlanner.cycleList(for: result)),
                preselected: result.key,
                hint: FillPlanner.hint(for: result)
            )

        case let .choose(ranked, hint):
            // Nothing matched a multi-line box: most likely a question the
            // policy didn't recognise, so a draft is the likelier pick.
            let likelyQuestion = LongAnswerPolicy.multiLineRoles.contains(field.context.role ?? "")
            presentPicker(
                field: field,
                anchor: anchor,
                ranked: pickerList(startingWith: ranked.map(\.key)),
                preselected: likelyQuestion && canOfferDraft(for: field) ? Self.draftRowKey : ranked.first?.key,
                hint: hint
            )

        case .draft:
            await draftAnswer(field, anchor: anchor)
        }
    }

    // MARK: Long answers

    /// Why a draft stopped before it finished.
    private enum DraftStop {
        case byUser
        case focusMoved
        /// The text in the box is no longer exactly what Control put there.
        case fieldChanged
        case couldNotInsert
    }

    /// The draft being written, if any. A second press of the trigger stops it.
    private var draftTask: Task<Void, Never>?
    private var draftStopRequested = false
    /// Drafts written recently, so the next question on the same form tells a
    /// different story, and learning from answers can tell Control's writing
    /// from the user's.
    private var history = DraftHistory()
    /// The last draft and the box it went in, for "press again for a
    /// different one". Kept for partial drafts too: stopping one and pressing
    /// again is the same request.
    private var lastDraftField: (element: AXUIElement, text: String, at: Date, savedAnswer: UUID, reused: Bool)?
    /// How long after a draft a press on the same, untouched box means
    /// "a different one" rather than "fill this".
    private static let redraftWindow: TimeInterval = 180

    /// Whether this text is a draft Control wrote, untouched. An edited draft
    /// is the user's writing and doesn't count.
    func isOwnDraft(_ text: String) -> Bool {
        let drafts = history.entries.map(\.text) + [lastDraftField?.text].compactMap { $0 }
        return drafts.contains { InsertionPlan.draftIsIntact(inserted: $0, current: text) }
    }

    /// Writes a first draft into an open-ended question, word by word as it
    /// streams in. Nothing from the vault goes into it; see `AnswerDrafter` for
    /// what does.
    /// - Parameter savedAnswer: the saved answer this draft becomes. A fresh
    ///   draft gets a new one; "press again" keeps the one it replaces.
    private func draftAnswer(
        _ field: FocusedField,
        anchor: NSRect?,
        previousDraft: String? = nil,
        savedAnswer: UUID? = nil
    ) async {
        draftStopRequested = false
        let task = Task {
            await self.writeDraft(field, anchor: anchor, previousDraft: previousDraft, savedAnswer: savedAnswer ?? UUID())
        }
        draftTask = task
        await task.value
        draftTask = nil
    }

    private func writeDraft(_ field: FocusedField, anchor: NSRect?, previousDraft: String?, savedAnswer: UUID) async {
        toast.show(title: previousDraft == nil ? "Writing a draft…" : "Writing a different draft…", detail: "",
                   symbol: "pencil.line", tone: .success, near: anchor, footnote: "Press again to stop",
                   duration: .seconds(45))

        let site = DraftHistory.site(for: field.context)

        // Asked before? Use what was written then, as the user left it. Not
        // when they've just asked for something different.
        if previousDraft == nil, preferences.reuseAnswers, let saved = await reusableAnswer(for: field, site: site) {
            guard !draftStopRequested else { return reportDraftStop(.byUser, wroteSomething: false, anchor: anchor) }
            return await useSavedAnswer(saved, in: field, site: site, anchor: anchor)
        }
        var client = ClaudeClient(apiKey: preferences.claudeAPIKey)
        let preferences = self.preferences
        let model = client.model
        client.onUsage = { usage in
            Task { @MainActor in preferences.recordUsage(.draft, dollars: usage.dollars(for: model)) }
        }
        let drafter = AnswerDrafter(client: client)
        let pieces = drafter.draft(
            for: field.context,
            pageTitle: windowTitle(of: field.app),
            aboutYou: preferences.aboutYou,
            learned: preferences.learnedFacts,
            otherAnswers: history.others(on: site, excluding: field.context.signature),
            previousDraft: previousDraft,
            pageText: PageTextReader.excerpt(around: field.element)
        )

        var chunker = DraftChunker()
        var inserted = ""
        // Whatever made it into the field, however the draft ended.
        defer {
            if !inserted.isEmpty {
                lastDraftField = (field.element, inserted, Date(), savedAnswer, false)
                answerWatcher?.watchDraft(field.element, context: field.context, savedAnswer: savedAnswer, text: inserted)
            }
        }
        var ladder = InsertionPlan.streaming
        var gathered: String?

        do {
            // Leaving this loop early — any `return` — cancels the request.
            for try await delta in pieces {
                if let stop = await place(chunker.feed(delta), in: field, inserted: &inserted,
                                          ladder: &ladder, gathered: &gathered) {
                    return reportDraftStop(stop, wroteSomething: !inserted.isEmpty, anchor: anchor)
                }
            }
            if draftStopRequested {
                return reportDraftStop(.byUser, wroteSomething: !inserted.isEmpty, anchor: anchor)
            }
            if let stop = await place(chunker.finish(), in: field, inserted: &inserted,
                                      ladder: &ladder, gathered: &gathered) {
                return reportDraftStop(stop, wroteSomething: !inserted.isEmpty, anchor: anchor)
            }
        } catch {
            if draftStopRequested || error is CancellationError {
                return reportDraftStop(.byUser, wroteSomething: !inserted.isEmpty, anchor: anchor)
            }
            toast.show(title: inserted.isEmpty ? "Couldn't write a draft" : "The draft stopped partway",
                       detail: error.localizedDescription, symbol: "xmark.circle", tone: .warning, near: anchor)
            Log.match.error("Drafting failed after \(inserted.count) characters: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Nothing but a paste worked here, so the draft was gathered instead.
        if let gathered {
            guard TextInserter.isStillFocused(field.element) else {
                return reportDraftStop(.focusMoved, wroteSomething: false, anchor: anchor)
            }
            guard InsertionPlan.draftIsIntact(inserted: "", current: AX.rawValue(field.element, kAXValueAttribute)) else {
                return reportDraftStop(.fieldChanged, wroteSomething: false, anchor: anchor)
            }
            guard let strategy = await TextInserter.insert(gathered, into: field.element, allowClipboard: true) else {
                return reportDraftStop(.couldNotInsert, wroteSomething: false, anchor: anchor)
            }
            ladder = [strategy]
            inserted = gathered
        }

        guard !inserted.isEmpty else {
            toast.show(title: "Couldn't write a draft", detail: ClaudeError.empty.localizedDescription,
                       symbol: "xmark.circle", tone: .warning, near: anchor)
            return
        }

        // Length only: the answer is the user's writing, not something to log.
        Log.insert.info("Drafted \(inserted.count) characters via \(ladder.first?.rawValue ?? "?", privacy: .public).")
        history.record(DraftHistory.Entry(
            question: Self.question(of: field.context),
            text: inserted,
            site: site,
            field: field.context.signature,
            savedAnswer: savedAnswer
        ))
        reportDraftWritten(inserted, limit: LengthLimit.find(in: field.context), near: AX.frame(field.element))
    }

    // MARK: Saved answers

    static func question(of context: FieldContext) -> String {
        LongAnswerPolicy.question(in: context) ?? context.label ?? context.labelCell ?? ""
    }

    /// A saved answer to this question, if there is one that fits this box and
    /// hasn't already been used on this form. The same wording is found here;
    /// a reworded question is Jev's call, and only question text goes to Jev.
    private func reusableAnswer(for field: FocusedField, site: String) async -> SavedAnswer? {
        let question = Self.question(of: field.context)
        let usedHere = Set(history.others(on: site, excluding: field.context.signature).compactMap(\.savedAnswer))
        let library = preferences.savedAnswers.filter {
            !usedHere.contains($0.id) && AnswerLibrary.fits($0.text, in: field.context)
        }
        guard !question.isEmpty, !library.isEmpty else { return nil }

        if let exact = AnswerLibrary.exactMatch(for: question, in: library) { return exact }

        guard preferences.jevEnabled, !preferences.jevAPIKey.isEmpty else { return nil }
        let candidates = AnswerLibrary.candidates(for: question, in: library)
        do {
            let answers = try await JevClient(apiKey: preferences.jevAPIKey).decide(
                state: AnswerReuse.state(question: question, site: field.context.domain),
                questions: AnswerReuse.questions(for: candidates)
            )
            return AnswerReuse.pick(answers, from: candidates)
        } catch {
            // No match is the safe answer: a fresh draft follows.
            Log.match.error("Couldn't compare with saved answers: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func useSavedAnswer(_ saved: SavedAnswer, in field: FocusedField, site: String, anchor: NSRect?) async {
        guard TextInserter.isStillFocused(field.element) else {
            return reportDraftStop(.focusMoved, wroteSomething: false, anchor: anchor)
        }
        guard InsertionPlan.draftIsIntact(inserted: "", current: AX.rawValue(field.element, kAXValueAttribute)) else {
            return reportDraftStop(.fieldChanged, wroteSomething: false, anchor: anchor)
        }
        guard await TextInserter.insert(saved.text, into: field.element, allowClipboard: true) != nil else {
            return reportDraftStop(.couldNotInsert, wroteSomething: false, anchor: anchor)
        }

        lastDraftField = (field.element, saved.text, Date(), saved.id, true)
        history.record(DraftHistory.Entry(question: Self.question(of: field.context), text: saved.text, site: site,
                                          field: field.context.signature, savedAnswer: saved.id))
        answerWatcher?.watchDraft(field.element, context: field.context, savedAnswer: saved.id, text: saved.text)
        Log.insert.info("Reused a saved answer (\(saved.text.count) characters).")
        toast.show(title: "Used your earlier answer", detail: "From “\(saved.questions.first ?? "an earlier question")”",
                   symbol: "clock.arrow.circlepath", tone: .success, near: AX.frame(field.element),
                   footnote: "Press again for a new draft", duration: .seconds(3))
    }

    /// Says how long the draft came out, and warns when it's over a limit the
    /// question states. The model is told the limit; this checks it kept to it.
    private func reportDraftWritten(_ text: String, limit: LengthLimit?, near anchor: NSRect?) {
        let words = LengthLimit.wordCount(text)
        let footnote = "Press again for a different draft"
        if let limit, limit.isExceeded(by: text) {
            let unit = limit.unit == .words ? "words" : "characters"
            toast.show(title: "Draft written, but it's long",
                       detail: "\(limit.count(text)) \(unit), over the \(limit.value)-\(unit.dropLast()) limit",
                       symbol: "exclamationmark.triangle.fill", tone: .warning, near: anchor, footnote: footnote,
                       duration: .seconds(4))
            return
        }
        toast.show(title: "Draft written", detail: "\(words) words. Read it over before you send it.",
                   symbol: "checkmark.circle.fill", tone: .success, near: anchor, footnote: footnote,
                   duration: .seconds(3))
    }

    // MARK: A different draft

    /// A press on a box still holding exactly the draft Control just wrote
    /// asks for a different one: clear it, and draft again with the old one
    /// shown as what to move away from.
    private func redraftIfRepeat(_ field: FocusedField) async -> Bool {
        guard let last = lastDraftField,
              Date().timeIntervalSince(last.at) < Self.redraftWindow,
              AX.same(last.element, field.element),
              let current = AX.rawValue(field.element, kAXValueAttribute),
              InsertionPlan.draftIsIntact(inserted: last.text, current: current),
              preferences.canDraftAnswers
        else { return false }

        let anchor = AX.frame(field.element)
        guard await clearDraft(in: field.element) else {
            toast.show(title: "Couldn't clear the draft", detail: "Delete it by hand and try again.",
                       symbol: "xmark.circle", tone: .warning, near: anchor)
            return true
        }

        var context = field.context
        context.isEmpty = true
        // A new draft in place of a reused answer is a new answer; in place of
        // a draft, it's the same answer, rewritten.
        await draftAnswer(FocusedField(element: field.element, context: context, app: field.app),
                          anchor: anchor, previousDraft: last.text, savedAnswer: last.reused ? nil : last.savedAnswer)
        return true
    }

    /// Empties a box holding a draft, most precise method first, checking the
    /// box after each. Never deletes past what's there: the backspace fallback
    /// only runs with the caret at the end.
    private func clearDraft(in element: AXUIElement) async -> Bool {
        await TextInserter.waitForModifierRelease()
        guard let before = AX.rawValue(element, kAXValueAttribute) else { return false }
        if before.isEmpty { return true }

        // Select everything, then replace the selection with nothing.
        var all = CFRange(location: 0, length: before.utf16.count)
        if let range = AXValueCreate(.cfRange, &all), AX.set(element, kAXSelectedTextRangeAttribute, range) {
            if AX.set(element, kAXSelectedTextAttribute, "" as CFTypeRef), await becomesEmpty(element) { return true }
            // The selection took but the write didn't: one Delete clears it.
            await TextInserter.deleteBackwards(count: 1)
            if await becomesEmpty(element) { return true }
        }

        // Last resort, one character at a time, and only from the end.
        guard let remaining = AX.rawValue(element, kAXValueAttribute), caretIsAtEnd(of: element, in: remaining)
        else { return false }
        await TextInserter.deleteBackwards(count: remaining.count)
        return await becomesEmpty(element, within: .seconds(2))
    }

    private func becomesEmpty(_ element: AXUIElement, within timeout: Duration = .milliseconds(300)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if (AX.rawValue(element, kAXValueAttribute) ?? "x").isEmpty { return true }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private func caretIsAtEnd(of element: AXUIElement, in value: String) -> Bool {
        guard let raw = AX.copy(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return false }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return false }
        return range.length == 0 && range.location == value.utf16.count
    }

    /// Puts one piece of the draft in the field, or says why it has to stop.
    ///
    /// Checked before every piece, because typing goes wherever focus is: the
    /// user can click away, type, or ask it to stop at any point in a stream
    /// that runs for several seconds.
    private func place(
        _ piece: String,
        in field: FocusedField,
        inserted: inout String,
        ladder: inout [InsertionStrategy],
        gathered: inout String?
    ) async -> DraftStop? {
        if draftStopRequested { return .byUser }
        guard !piece.isEmpty else { return nil }
        if gathered != nil {
            gathered?.append(piece)
            return nil
        }

        guard TextInserter.isStillFocused(field.element) else { return .focusMoved }
        guard await draftSettles(in: field.element, to: inserted) else { return .fieldChanged }

        guard let strategy = await TextInserter.append(piece, into: field.element, using: ladder) else {
            // Only the first piece may fall back to gathering: nothing is in
            // the field yet, so the whole draft can still go in as one paste.
            guard inserted.isEmpty else { return .couldNotInsert }
            gathered = piece
            return nil
        }
        ladder = [strategy]
        inserted += piece
        return nil
    }

    /// Whether the field holds exactly the draft so far. Typed pieces can still
    /// be landing when the next one is ready, so this waits briefly before
    /// deciding the user changed something.
    private func draftSettles(in element: AXUIElement, to inserted: String) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while true {
            if InsertionPlan.draftIsIntact(inserted: inserted, current: AX.rawValue(element, kAXValueAttribute)) {
                return true
            }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func reportDraftStop(_ stop: DraftStop, wroteSomething: Bool, anchor: NSRect?) {
        let kept = wroteSomething ? "What's written so far stays." : "Nothing was added."
        let (title, detail) = switch stop {
        case .byUser: ("Draft stopped", kept)
        case .focusMoved: ("Focus moved", kept)
        case .fieldChanged: ("Draft stopped", "The text box changed while it was being written.")
        case .couldNotInsert: ("Couldn't keep typing here", kept)
        }
        toast.show(title: title, detail: detail, symbol: "stop.circle", tone: .warning, near: anchor)
        Log.insert.info("Draft stopped (\(String(describing: stop), privacy: .public)).")
    }

    // MARK: Drafting on request

    /// Not a vault key: vault keys are snake_case words, and this can't be one.
    private static let draftRowKey = "control.draft-answer"

    private static let draftRow = PickerRow(
        key: draftRowKey,
        label: "Write an answer",
        category: "Draft",
        preview: "A first draft from what you've told Control",
        sensitive: false,
        score: 0,
        symbol: "pencil.line"
    )

    /// The picker offers a draft for any empty box once drafting is set up,
    /// so a question the policy didn't recognise is one pick away. An answer
    /// is never drafted on top of text.
    private func canOfferDraft(for field: FocusedField) -> Bool {
        preferences.canDraftAnswers && field.context.isEmpty && !field.context.isSecureField
    }

    /// The front window's title: in a browser, the page title, which usually
    /// names the organization asking ("Application for … at …").
    private func windowTitle(of app: NSRunningApplication) -> String? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return AX.element(appElement, kAXFocusedWindowAttribute).flatMap { AX.string($0, kAXTitleAttribute) }
    }

    private func presentPicker(
        field: FocusedField,
        anchor: NSRect?,
        ranked: [String],
        preselected: String?,
        hint: String?
    ) {
        var rows = pickerRows(for: ranked)
        if canOfferDraft(for: field) { rows.insert(Self.draftRow, at: 0) }
        guard !rows.isEmpty else {
            toast.show(title: BlockReason.emptyVault.message, detail: "", symbol: "tray", tone: .warning, near: anchor)
            return
        }

        picker.show(
            title: field.context.label ?? field.context.placeholder ?? "Fill this field",
            hint: hint,
            rows: rows,
            preselected: preselected,
            near: anchor,
            onCommit: { [weak self] key in
                guard let self else { return }
                if key == Self.draftRowKey {
                    Task {
                        await self.restoreFocusIfNeeded(field)
                        await self.draftAnswer(field, anchor: anchor)
                    }
                    return
                }
                // A deliberate pick ends the cycle. Pressing again means "show me
                // the list again", not "try the next one".
                self.preferences.rememberProfile(self.vault.activeProfileID, for: field.context)
                Task { await self.perform(key, field: field, source: .manual, userConfirmed: true, ranked: [key]) }
            },
            onCancel: {}
        )
    }

    /// Resolves the value, hands focus back if the picker took it, inserts, and
    /// reports. The Keychain read for a sensitive field happens here and nowhere
    /// earlier — this is the first point at which the user has actually chosen.
    private func perform(
        _ key: String,
        field: FocusedField,
        source: MatchSource,
        userConfirmed: Bool,
        ranked: [String]
    ) async {
        let anchor = AX.frame(field.element)
        guard let definition = vault.field(for: key) else { return }

        let value: String?
        do {
            value = try vault.resolvedValue(
                for: key,
                context: field.context,
                authenticationPrompt: "fill your \(definition.label.lowercased())"
            )
        } catch {
            toast.show(title: "Couldn't unlock \(definition.label)", detail: error.localizedDescription, symbol: "lock.slash", tone: .warning, near: anchor)
            return
        }

        guard var value, !value.isEmpty else {
            toast.show(title: "\(definition.label) is empty", detail: "Add it in Control's settings.", symbol: "tray", tone: .warning, near: anchor)
            return
        }

        // A snippet holds a template. Expanding here rather than in the vault
        // keeps the clock and the pasteboard out of ControlKit.
        var caretOffset: Int?
        if definition.isSnippet {
            let expanded = TemplateEngine.expand(value, in: environment(for: field.context))
            value = expanded.text
            caretOffset = expanded.cursorOffset
            if !expanded.isFullyResolved {
                Log.match.info("Snippet left \(expanded.unresolved.count) placeholder(s) unresolved.")
            }
        }

        await restoreFocusIfNeeded(field)

        let strategy = await TextInserter.insert(
            value,
            into: field.element,
            allowClipboard: !definition.sensitive
        )

        guard let strategy else {
            toast.show(title: "Couldn't fill this field", detail: "No insertion method worked here.", symbol: "xmark.circle", tone: .warning, near: anchor)
            Log.insert.error("All insertion strategies failed in \(field.context.appName, privacy: .public).")
            return
        }

        // `{cursor}` asked for the caret to land somewhere specific.
        if let caretOffset { TextInserter.placeCaret(in: field.element, offsetFromEnd: value.utf16.count - caretOffset) }

        Log.insert.info("Filled \(key, privacy: .public) via \(strategy.rawValue, privacy: .public).")
        coordinator.remember(key, for: field.context, source: source, userConfirmed: userConfirmed)

        lastFill = FillPlanner.LastFill(
            signature: field.context.signature,
            ranked: ranked,
            index: ranked.firstIndex(of: key) ?? 0,
            insertedText: value,
            at: Date()
        )
        lastElement = field.element

        toast.show(
            title: definition.label,
            detail: definition.sensitive ? String(repeating: "•", count: min(value.count, 12)) : value,
            symbol: definition.sensitive ? "lock.fill" : "checkmark.circle.fill",
            tone: .success,
            near: anchor,
            footnote: ranked.count > 1 && source != .manual ? "Press again for a different one" : nil
        )

        watchedContext = field.context
        corrections.watch(field.element, pid: field.app.processIdentifier, ignoring: value)
    }

    // MARK: Learning from a hand edit

    private var watchedContext: FieldContext?

    /// The user replaced what Control filled. If the replacement is a value the
    /// vault already holds, that identifies the field precisely — remember it.
    ///
    /// Anything else is left alone. A value Control does not recognise says the
    /// field wants something it has never been told about, and guessing a key
    /// from it would poison the cache with a wrong answer that then sticks.
    private func learnFromEdit(_ typed: String) {
        guard let context = watchedContext else { return }
        guard let key = vaultKey(matching: typed, in: context) else { return }

        coordinator.remember(key, for: context, source: .manual, userConfirmed: true)
        corrections.stop()

        guard let definition = vault.field(for: key) else { return }
        toast.show(
            title: "Got it — \(definition.label)",
            detail: "Control will use this here from now on.",
            symbol: "brain",
            tone: .success,
            near: nil
        )
        Log.match.info("Learned \(key, privacy: .public) from a hand edit.")
    }

    private func vaultKey(matching typed: String, in context: FieldContext) -> String? {
        let needle = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }

        // Best effort: a value that can't be read just can't be recognised, and
        // nothing is learned from it. No fill depends on this.
        for field in vault.fillableFields where !field.sensitive {
            guard let value = try? vault.resolvedValue(for: field.key, context: context),
                  !value.isEmpty
            else { continue }
            if value.lowercased() == needle { return field.key }
        }
        return nil
    }

    /// The picker takes key focus. `.nonactivatingPanel` usually leaves the other
    /// app active anyway, but if it did get pushed back, bring it forward before
    /// synthesizing keystrokes at it.
    private func restoreFocusIfNeeded(_ field: FocusedField) async {
        guard !field.app.isActive else { return }
        field.app.activate()
        try? await Task.sleep(for: .milliseconds(90))
    }

    // MARK: Repeat-press cycling

    /// A second press on the same field swaps in the next candidate. Whether this
    /// press counts as a repeat, and what it should do, is `FillPlanner`'s call.
    private func cycleIfRepeat(_ field: FocusedField) async -> Bool {
        let action = FillPlanner.repeatAction(
            after: lastFill,
            signature: field.context.signature,
            fieldValue: AX.rawValue(field.element, kAXValueAttribute)
        )

        switch action {
        case .fresh:
            return false

        case .exhausted:
            lastFill = nil
            presentPicker(
                field: field,
                anchor: AX.frame(field.element),
                ranked: pickerList(startingWith: []),
                preselected: nil,
                hint: "Nothing else looked likely — pick one"
            )
            return true

        case let .cycle(nextKey, nextIndex):
            guard let last = lastFill, let definition = vault.field(for: nextKey) else { return false }

            let value: String?
            do {
                value = try vault.resolvedValue(
                    for: nextKey,
                    context: field.context,
                    authenticationPrompt: "fill your \(definition.label.lowercased())"
                )
            } catch {
                return false
            }
            guard let value, !value.isEmpty else { return false }

            await TextInserter.deleteBackwards(count: last.insertedText.count)
            guard await TextInserter.insert(value, into: field.element, allowClipboard: !definition.sensitive) != nil
            else { return false }

            // Remembered, never locked: only an explicit choice is deliberate.
            coordinator.remember(nextKey, for: field.context, source: .manual,
                                 userConfirmed: FillPlanner.isDeliberate(.cache))

            lastFill = FillPlanner.LastFill(
                signature: last.signature,
                ranked: last.ranked,
                index: nextIndex,
                insertedText: value,
                at: Date()
            )
            lastElement = field.element

            toast.show(
                title: definition.label,
                detail: definition.sensitive ? String(repeating: "•", count: min(value.count, 12)) : value,
                symbol: "arrow.triangle.2.circlepath",
                tone: .success,
                near: AX.frame(field.element)
            )
            return true
        }
    }

    // MARK: Row construction

    private func pickerList(startingWith keys: [String]) -> [String] {
        // Snippets belong here even though nothing guesses them: the picker is
        // where you reach for something by name.
        FillPlanner.pickerList(startingWith: keys, allFillable: vault.fillableFields.map(\.key))
    }

    /// Builds the picker list. Previews come from the Keychain for ordinary
    /// fields and are masked for sensitive ones, so opening the picker never
    /// raises an authentication prompt.
    private func pickerRows(for keys: [String]) -> [PickerRow] {
        keys.compactMap { key in
            guard let field = vault.field(for: key) else { return nil }
            let preview: String
            if field.sensitive {
                preview = "••••••"
            } else if let stored = try? vault.storedValue(for: key) {  // preview only; committing reads again and reports failures
                preview = String(stored.prefix(40))
            } else {
                preview = ""
            }
            let source = vault.profile(providing: key)
            return PickerRow(
                key: key,
                label: field.label,
                category: field.category.title,
                preview: preview,
                sensitive: field.sensitive,
                score: 0,
                inheritedFrom: source == vault.activeProfileID
                    ? nil
                    : VaultProfile.builtIn.first { $0.id == source }?.name
            )
        }
    }
}
