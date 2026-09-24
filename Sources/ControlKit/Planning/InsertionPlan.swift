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
    ///
    /// Web content never gets `.axValue`. Setting a web field's whole value
    /// writes past the page's own input handling: React, Vue and Angular keep
    /// their own copy of the value and never hear about it, so the page shows
    /// the text and still validates and submits the field as empty. That is
    /// "Please enter a valid phone number" with the number sitting right there.
    /// Inserting at the caret and typing both go through the page's editing,
    /// which is what its handlers listen to.
    public static func strategies(
        fieldIsEmpty: Bool,
        allowClipboard: Bool,
        inWebContent: Bool = false
    ) -> [InsertionStrategy] {
        var ladder: [InsertionStrategy] = [.axSelectedText]
        // Setting the whole value replaces rather than inserts, so it is only safe
        // when there is nothing to destroy.
        if fieldIsEmpty, !inWebContent { ladder.append(.axValue) }
        ladder.append(.unicodeEvents)
        if allowClipboard { ladder.append(.clipboard) }
        return ladder
    }

    /// The ladder for a draft arriving in pieces, tried on the first piece;
    /// whichever rung works is then used for the rest.
    ///
    /// Only rungs that insert at the caret. Setting the whole value leaves the
    /// caret wherever the app decides, and the next piece could land in front
    /// of the last. Pasting every few words would churn the user's clipboard;
    /// when nothing else works the draft is gathered and pasted once at the end.
    public static let streaming: [InsertionStrategy] = [.axSelectedText, .unicodeEvents]

    /// Whether a field holding a draft still holds exactly what Control put
    /// there, so the next piece may follow it.
    ///
    /// False the moment the user types, deletes or pastes in the middle of a
    /// draft: the pieces after that would go wherever their caret now is.
    /// Whitespace is compared loosely, since editors differ in how they report
    /// line breaks and runs of spaces. `nil` is a field that doesn't report its
    /// value, and there is nothing to compare.
    public static func draftIsIntact(inserted: String, current: String?) -> Bool {
        guard let current else { return true }
        return collapsingWhitespace(current) == collapsingWhitespace(inserted)
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
