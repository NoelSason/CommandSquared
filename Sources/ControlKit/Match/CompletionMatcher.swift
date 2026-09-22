import Foundation

/// Decides whether what someone has typed is the beginning of a stored value.
///
/// A literal prefix test is too strict for the values people actually store.
/// Nobody types `https://` to reach their GitHub profile — they type `githu`,
/// and mean the same thing. So a match is allowed to begin at any *token*
/// boundary inside the value, the way a browser address bar behaves.
///
/// The completion is always the whole stored value, scheme included. Matching is
/// lenient about where it starts; what gets inserted is not.
public enum CompletionMatcher {
    /// Characters after which a new token begins. Typing `gmail` should find the
    /// host inside `noel@gmail.com`, and `NoelSason` the last path segment.
    private static let boundaries: Set<Character> = ["/", ".", "@", "-", "_", " ", ":", "+", ","]

    /// The index in `value` just past the matched text, or nil if it doesn't match.
    ///
    /// The index is where a selection should begin: everything before it is what
    /// the user effectively typed, everything after is the suggestion.
    public static func matchEnd(of typed: String, in value: String) -> Int? {
        let needle = typed.lowercased()
        let haystack = value.lowercased()

        guard !needle.isEmpty, haystack.count > needle.count else { return nil }

        let characters = Array(haystack)
        let needleCharacters = Array(needle)

        for start in 0 ... (characters.count - needleCharacters.count) {
            guard isTokenStart(characters, at: start) else { continue }
            guard Array(characters[start ..< start + needleCharacters.count]) == needleCharacters else { continue }
            return start + needleCharacters.count
        }
        return nil
    }

    private static func isTokenStart(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        return boundaries.contains(characters[index - 1])
    }
}
