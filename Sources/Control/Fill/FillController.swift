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

    /// When the inspector window is open the hotkey captures instead of filling,
    /// so the capture layer can be validated without anything being typed.
    var inspectorIsOpen = false
    var onInspect: (@MainActor (FieldContext, [(String, String)]) -> Void)?

    /// State for repeat-press cycling.
    private struct LastFill {
        let signature: String
        let element: AXUIElement
        let ranked: [String]
        let index: Int
        let insertedText: String
        let at: Date
        let context: FieldContext
    }

    private var lastFill: LastFill?
    /// How long after a fill a second press means "wrong one, try the next"
    /// rather than "fill this again". Long enough to read the field and react.
    private static let cycleWindow: TimeInterval = 5.0

    init(vault: VaultStore, cache: MatchCache, preferences: Preferences) {
        self.vault = vault
        self.cache = cache
        self.preferences = preferences
        coordinator = MatchCoordinator(vault: vault, cache: cache, preferences: preferences)
    }

    // MARK: Entry point

    func handleHotkey() async {
        guard !picker.isVisible else { return }

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
            if await cycleIfRepeat(field) { return }
            await fill(field)
        }
    }

    // MARK: Fill

    private func fill(_ field: FocusedField) async {
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
            await perform(result.key, field: field, source: result.source, userConfirmed: false, ranked: ranking(for: result))

        case let .confirm(result):
            presentPicker(
                field: field,
                anchor: anchor,
                ranked: ranking(for: result),
                preselected: result.key,
                hint: hint(for: result)
            )

        case let .choose(ranked, hint):
            presentPicker(
                field: field,
                anchor: anchor,
                ranked: ranked.map(\.key),
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
                Task { await self.perform(key, field: field, source: .manual, userConfirmed: true, ranked: ranked) }
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

        guard let value, !value.isEmpty else {
            toast.show(title: "\(definition.label) is empty", detail: "Add it in Control's settings.", symbol: "tray", tone: .warning, near: anchor)
            return
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

        Log.insert.info("Filled \(key, privacy: .public) via \(strategy.rawValue, privacy: .public).")
        coordinator.remember(key, for: field.context, source: source, userConfirmed: userConfirmed)

        lastFill = LastFill(
            signature: field.context.signature,
            element: field.element,
            ranked: ranked,
            index: ranked.firstIndex(of: key) ?? 0,
            insertedText: value,
            at: Date(),
            context: field.context
        )

        toast.show(
            title: definition.label,
            detail: definition.sensitive ? String(repeating: "•", count: min(value.count, 12)) : value,
            symbol: definition.sensitive ? "lock.fill" : "checkmark.circle.fill",
            tone: .success,
            near: anchor,
            footnote: ranked.count > 1 && source != .manual ? "Press again for a different one" : nil
        )
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

    /// A second press on the same field within the cycle window swaps in the next
    /// candidate instead of starting over — the fast correction when the top guess
    /// was close but wrong.
    private func cycleIfRepeat(_ field: FocusedField) async -> Bool {
        guard let last = lastFill,
              last.signature == field.context.signature,
              Date().timeIntervalSince(last.at) < Self.cycleWindow,
              last.ranked.count > 1
        else { return false }

        // Only cycle when the previous insertion is still verifiably there, so a
        // backspace run cannot eat text the user typed.
        guard let current = AX.rawValue(field.element, kAXValueAttribute),
              current.hasSuffix(last.insertedText)
        else { return false }

        let nextIndex = (last.index + 1) % last.ranked.count
        let nextKey = last.ranked[nextIndex]
        guard let definition = vault.field(for: nextKey) else { return false }

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
        let strategy = await TextInserter.insert(value, into: field.element, allowClipboard: !definition.sensitive)
        guard strategy != nil else { return false }

        coordinator.remember(nextKey, for: field.context, source: .manual, userConfirmed: true)
        lastFill = LastFill(
            signature: last.signature,
            element: field.element,
            ranked: last.ranked,
            index: nextIndex,
            insertedText: value,
            at: Date(),
            context: field.context
        )

        toast.show(
            title: definition.label,
            detail: definition.sensitive ? String(repeating: "•", count: min(value.count, 12)) : value,
            symbol: "arrow.triangle.2.circlepath",
            tone: .success,
            near: AX.frame(field.element)
        )
        return true
    }

    // MARK: Row construction

    private func ranking(for result: MatchResult) -> [String] {
        var keys = [result.key] + result.alternatives.map(\.key)
        var seen = Set(keys)
        for field in vault.fillableFields where seen.insert(field.key).inserted {
            keys.append(field.key)
        }
        return keys
    }

    private func hint(for result: MatchResult) -> String? {
        switch result.source {
        case .cache: "Remembered from last time"
        case .local: nil
        case .jev: "Jev's best guess — \(Int(result.confidence * 100))% confident"
        case .manual: nil
        }
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
            } else if let stored = try? vault.storedValue(for: key) {
                preview = String(stored.prefix(40))
            } else {
                preview = ""
            }
            return PickerRow(
                key: key,
                label: field.label,
                category: field.category.title,
                preview: preview,
                sensitive: field.sensitive,
                score: 0
            )
        }
    }
}
