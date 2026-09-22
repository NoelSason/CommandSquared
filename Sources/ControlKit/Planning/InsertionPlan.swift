import Foundation

public enum InsertionStrategy: String, Sendable, CaseIterable {
    case axSelectedText
    case axValue
    case unicodeEvents
    case clipboard

    public var description: String {
        switch self {
        case .axSelectedText: "accessibility (insert at caret)"
        case .axValue: "accessibility (set value)"
        case .unicodeEvents: "synthesized keystrokes"
        case .clipboard: "clipboard paste"
        }
    }

    /// True for strategies that put the value on the pasteboard or type it as
    /// keystrokes, where other software can observe it.
    public var isObservable: Bool {
        switch self {
        case .clipboard: true
        case .axSelectedText, .axValue, .unicodeEvents: false
        }
    }
}

/// Chooses how to get text into a field, and — more importantly — decides when an
/// attempt has actually failed.
///
/// The second part is where "NoelNoel" came from. Chromium returns success from
/// an accessibility write immediately and applies it a frame or two later, so an
/// instant read sees the old value, concludes the write failed, and escalates to
/// typing — which lands on top of the write still in flight.
public enum InsertionPlan {
    /// The ladder, most precise first.
    ///
    /// Synthesized keystrokes sit *above* the clipboard deliberately: they work in
    /// web and Electron content where accessibility writes silently no-op, and
    /// they never touch the pasteboard.
    public static func strategies(fieldIsEmpty: Bool, allowClipboard: Bool) -> [InsertionStrategy] {
        var ladder: [InsertionStrategy] = [.axSelectedText]
        // Setting the whole value replaces rather than inserts, so it is only safe
        // when there is nothing to destroy.
        if fieldIsEmpty { ladder.append(.axValue) }
        ladder.append(.unicodeEvents)
        if allowClipboard { ladder.append(.clipboard) }
        return ladder
    }

    /// Whether a write that reported success has actually shown up.
    ///
    /// `before == nil` means the field never reports its value, so there is
    /// nothing to compare and the API's word is all there is.
    public static func landed(before: String?, current: String?) -> Bool {
        guard let before else { return true }
        return current != before
    }

    /// Whether it is safe to escalate to a strategy that types or pastes.
    ///
    /// Refuses once anything has changed the field, however late. This is the
    /// guard that stops a slow accessibility write from being duplicated by the
    /// keystrokes sent to replace it.
    public static func mayEscalate(before: String?, current: String?) -> Bool {
        guard let before else { return true }
        return current == before
    }

    /// How long to wait for a write to appear before treating it as failed.
    public static let verificationWindow: Duration = .milliseconds(200)
    public static let verificationPoll: Duration = .milliseconds(6)
    /// The hotkey's own modifiers are very likely still held; typing into that is
    /// how every synthesized keystroke becomes a menu shortcut.
    public static let modifierReleaseTimeout: Duration = .milliseconds(400)
}
