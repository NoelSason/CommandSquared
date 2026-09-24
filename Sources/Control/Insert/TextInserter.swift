import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ControlKit
import Foundation

/// Gets text into the focused field, trying progressively more forceful methods.
///
/// Order matters. Accessibility writes are clean and invisible but silently
/// no-op in a lot of web and Electron content. Synthesized Unicode keystrokes
/// work almost everywhere and — importantly — never touch the clipboard, which
/// is why they sit *above* the clipboard fallback rather than below it.
@MainActor
enum TextInserter {
    /// Carries out an `InsertionPlan`. It decides nothing: which strategies to
    /// try, whether one landed, and whether escalating is safe are all settled in
    /// `ControlKit` where they can be tested.
    static func insert(
        _ text: String,
        into element: AXUIElement,
        allowClipboard: Bool
    ) async -> InsertionStrategy? {
        guard !text.isEmpty else { return nil }

        // The trigger's own modifiers are very likely still held. Typing now would
        // turn every synthesized keystroke into a menu shortcut.
        await waitForModifierRelease()

        let before = AX.rawValue(element, kAXValueAttribute)
        let ladder = InsertionPlan.strategies(
            fieldIsEmpty: before?.isEmpty ?? true,
            allowClipboard: allowClipboard,
            inWebContent: BrowserURLReader.isInsideWebArea(element)
        )
        return await climb(ladder, text: text, element: element, before: before)
    }

    /// Adds one piece of a draft at the caret, trying only the given rungs —
    /// `InsertionPlan.streaming` for the first piece, then whichever of those
    /// worked. See `InsertionPlan.streaming` for why the ladder is shorter.
    static func append(
        _ text: String,
        into element: AXUIElement,
        using ladder: [InsertionStrategy]
    ) async -> InsertionStrategy? {
        guard !text.isEmpty else { return nil }
        await waitForModifierRelease()
        let before = AX.rawValue(element, kAXValueAttribute)
        return await climb(ladder, text: text, element: element, before: before)
    }

    private static func climb(
        _ ladder: [InsertionStrategy],
        text: String,
        element: AXUIElement,
        before: String?
    ) async -> InsertionStrategy? {
        for strategy in ladder {
            // A write from an earlier rung may only just have arrived. Typing on
            // top of one still in flight is how the value lands twice.
            guard InsertionPlan.mayEscalate(before: before, current: AX.rawValue(element, kAXValueAttribute)) else {
                return previousRung(before: strategy, in: ladder)
            }

            guard await attempt(strategy, text: text, element: element) else { continue }
            if await landed(element, from: before) { return strategy }
        }

        return InsertionPlan.mayEscalate(before: before, current: AX.rawValue(element, kAXValueAttribute))
            ? nil
            : ladder.last
    }

    /// Runs one rung. Returns whether it was worth waiting on the result.
    private static func attempt(
        _ strategy: InsertionStrategy,
        text: String,
        element: AXUIElement
    ) async -> Bool {
        switch strategy {
        case .axSelectedText:
            return AX.set(element, kAXSelectedTextAttribute, text as CFTypeRef)
        case .axValue:
            return AX.set(element, kAXValueAttribute, text as CFTypeRef)
        case .unicodeEvents:
            typeUnicode(text)
            return true
        case .clipboard:
            await pasteViaClipboard(text)
            return true
        }
    }

    private static func previousRung(
        before strategy: InsertionStrategy,
        in ladder: [InsertionStrategy]
    ) -> InsertionStrategy? {
        guard let index = ladder.firstIndex(of: strategy), index > 0 else { return ladder.first }
        return ladder[index - 1]
    }

    // MARK: Verification

    /// Waits for a write to actually show up in the field.
    ///
    /// Reading the value immediately after `AXUIElementSetAttributeValue` returns
    /// is not good enough: Chromium reports success straight away and applies the
    /// change a frame or two later. A single immediate read sees the old value,
    /// concludes the write failed, and escalates to synthesized typing — which
    /// then lands *on top of* the write that was quietly in flight. That is what
    /// produced "NoelNoel".
    private static func landed(
        _ element: AXUIElement,
        from before: String?,
        timeout: Duration = InsertionPlan.verificationWindow
    ) async -> Bool {
        // Nothing to compare against — give the write a beat and take its word.
        guard before != nil else {
            try? await Task.sleep(for: .milliseconds(30))
            return true
        }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if InsertionPlan.landed(before: before, current: AX.rawValue(element, kAXValueAttribute)) {
                return true
            }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: InsertionPlan.verificationPoll)
        }
    }

    /// True when the element the match was computed against is still the one the
    /// user is in. A Jev round trip is long enough for focus to move.
    static func isStillFocused(_ element: AXUIElement) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        guard let current = AX.element(systemWide, kAXFocusedUIElementAttribute) else { return false }
        return AX.same(current, element)
    }

    // MARK: Synthesized input

    static func waitForModifierRelease(timeout: Duration = InsertionPlan.modifierReleaseTimeout) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let held = NSEvent.modifierFlags.intersection([.command, .shift, .option, .control])
            if held.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Posts the text as keyboard events carrying a Unicode payload rather than a
    /// key code, so layout does not matter. `.privateState` gives the events their
    /// own modifier state, isolated from whatever the user is physically holding.
    private static func typeUnicode(_ text: String) {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let units = Array(text.utf16)
        let chunkSize = 16  // CGEvent's Unicode payload is small; chunk conservatively.

        for start in stride(from: 0, to: units.count, by: chunkSize) {
            let chunk = Array(units[start ..< min(start + chunkSize, units.count)])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }

            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Moves the caret back from where it ended up, for `{cursor}`.
    static func placeCaret(in element: AXUIElement, offsetFromEnd: Int) {
        guard offsetFromEnd > 0 else { return }
        var range = CFRange()
        guard let current = AX.copy(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(current) == AXValueGetTypeID(),
              AXValueGetValue(current as! AXValue, .cfRange, &range)
        else { return }

        var target = CFRange(location: max(0, range.location - offsetFromEnd), length: 0)
        if let position = AXValueCreate(.cfRange, &target) {
            AX.set(element, kAXSelectedTextRangeAttribute, position)
        }
    }

    /// Sends N backspaces. Used only by repeat-press cycling, and only after the
    /// caller has verified the text about to be removed is text Control inserted.
    static func deleteBackwards(count: Int) async {
        guard count > 0, let source = CGEventSource(stateID: .privateState) else { return }
        for _ in 0 ..< count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)
            else { return }
            down.flags = []
            up.flags = []
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
        try? await Task.sleep(for: .milliseconds(60))
    }

    /// Known lossy: only the plain-text flavour of the previous clipboard is put
    /// back, and clipboard managers will still have recorded the value. Disabled
    /// entirely for sensitive fields by the caller.
    private static func pasteViaClipboard(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)

        try? await Task.sleep(for: .milliseconds(150))
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
    }
}
