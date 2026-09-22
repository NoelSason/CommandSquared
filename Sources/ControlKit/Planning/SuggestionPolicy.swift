import Foundation

/// Decides whether a field may be completed as the user types, and from what.
///
/// Typing happens everywhere — spreadsheets, editors, terminals, message boxes —
/// and an earlier version offered the entire vault whenever the matcher had no
/// opinion. A cell that happened to start with the same letters as an email
/// address got completed. Silence is the correct behaviour in any field Control
/// cannot name.
public enum SuggestionPolicy {
    /// Below this almost everything matches and the suggestion is just noise.
    public static let minimumPrefix = 2
    /// Wait for a pause. Suggesting on every keystroke feels like being fought.
    public static let idleBeforeSuggesting: Duration = .milliseconds(140)

    public enum Refusal: String, Sendable, Equatable {
        case secureField
        case deniedApp
        case unlabelledField
        case tooFewCharacters
        case caretNotAtEnd
        case nothingPlausible
    }

    /// Gate on the field itself, before any candidate is considered.
    public static func refusal(
        context: FieldContext,
        isDenied: Bool,
        typed: String,
        caretAtEnd: Bool
    ) -> Refusal? {
        if context.isSecureField { return .secureField }
        if isDenied { return .deniedApp }
        // No label, placeholder, or help text means this is not a form field —
        // it is a cell, a line of code, or a message.
        if context.hasNoDescriptiveText { return .unlabelledField }
        if typed.count < minimumPrefix { return .tooFewCharacters }
        // Completing mid-word would mangle an edit in progress.
        if !caretAtEnd { return .caretNotAtEnd }
        return nil
    }

    /// The keys worth completing from, best first.
    ///
    /// Deliberately has no "and everything else" fallback. An empty result means
    /// no suggestion, which is the whole point — the full vault stays one trigger
    /// press away, it just is not volunteered.
    public static func candidates(
        learned: String?,
        ranked: [ScoredKey],
        allowed: Set<String>
    ) -> [String] {
        var ordered: [String] = []

        // A remembered answer for this exact field outranks everything.
        if let learned, allowed.contains(learned) {
            ordered.append(learned)
        }
        for scored in ranked where allowed.contains(scored.key) && !ordered.contains(scored.key) {
            ordered.append(scored.key)
        }
        return ordered
    }
}
