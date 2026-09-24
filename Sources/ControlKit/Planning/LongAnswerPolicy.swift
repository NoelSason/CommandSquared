import Foundation

/// Decides whether a field is asking for writing — "Tell us about a project
/// you're proud of" — rather than a saved detail.
///
/// Deliberately narrow, because the alternative to a missed essay is the
/// picker, and the alternative to a false positive is a paragraph typed into
/// someone's chat box. Three things must all hold:
///
/// 1. **The field is multi-line.** A single-line "How did you hear about us?"
///    wants three words; an essay there is wrong however good it is.
/// 2. **It is empty.** A draft never lands on top of what the user wrote.
/// 3. **Its label reads as an open question.** The label, label cell or help
///    text — never the placeholder alone. Chat and post boxes put their prompt
///    there ("What's on your mind?", "How can I help you today?"), and those
///    are not asking for an answer about the user.
public enum LongAnswerPolicy {
    public static let multiLineRoles: Set<String> = ["AXTextArea"]

    /// First words that open a prompt for writing, after any leading "please"
    /// or "briefly". "Write" is left out: "Write your prompt to Claude" is a
    /// chat box, not a question.
    static let openers: Set<String> = [
        "describe", "explain", "share", "discuss", "tell", "talk", "walk", "give",
        "reflect", "elaborate", "summarize", "outline", "introduce",
        "why", "what", "what's", "how", "which", "who", "when", "where",
    ]

    private static let softeners: Set<String> = ["please", "briefly", "kindly"]

    /// "(250 words)", "500 characters max", "in 100 words or fewer".
    private static let lengthLimit = #"\b\d{2,5}\s*(words?|characters?|chars)\b"#

    public static func isOpenEndedQuestion(_ context: FieldContext) -> Bool {
        guard context.isEmpty,
              let role = context.role, multiLineRoles.contains(role)
        else { return false }
        return question(in: context) != nil
    }

    /// The first of the field's own texts that reads as a question.
    public static func question(in context: FieldContext) -> String? {
        [context.label, context.labelCell, context.helpText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: readsAsQuestion)
    }

    static func readsAsQuestion(_ text: String) -> Bool {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let words = lowered
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
        guard words.count >= 2 else { return false }

        if lowered.contains("?") { return true }
        if lowered.range(of: lengthLimit, options: .regularExpression) != nil { return true }
        guard let first = words.first(where: { !softeners.contains($0) }) else { return false }
        return openers.contains(first)
    }
}
