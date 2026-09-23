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
        guard !picker.isVisible else { return }
        if let practiceHandler, await practiceHandler() { return }
        // Control's own windows are not something to fill, and reading them
        // through the Accessibility API from Control itself can hang.
        guard !NSRunningApplication.current.isActive else { return }
        if suggester?.cycle() == true { return }
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
            // Highlighted text containing {placeholders} is a template, and the
            // user is asking for it to be filled in — not for this field to be
            // matched against the vault.
            if await expandSelection(field) { return }
            if await cycleIfRepeat(field) { return }
            await fill(field)
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
        case .choose, .blocked: return nil
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
            presentPicker(
                field: field,
                anchor: anchor,
                ranked: pickerList(startingWith: ranked.map(\.key)),
                preselected: ranked.first?.key,
                hint: hint
            )
        }
    }

    private func presentPicker(
        field: FocusedField,
        anchor: NSRect?,
        ranked: [String],
        preselected: String?,
        hint: String?
    ) {
        let rows = pickerRows(for: ranked)
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
