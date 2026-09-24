import Foundation

/// Turns a streamed answer into pieces worth putting in a field: whole words,
/// without the reply's leading or trailing whitespace, and without em dashes.
///
/// The prompt asks for no em dashes; this is the guarantee. Each one becomes a
/// comma ("I built Scope — a search tool" reads "I built Scope, a search
/// tool"). A dash at the end of the text so far waits for what follows it, so
/// the spacing after the comma comes out right.
///
/// The model streams fragments of words. Typing each fragment as it arrives
/// would work, but every insertion is a round trip to another app, and a
/// half-typed word is what the user sees if the stream stops there. So the
/// text after the last space is held back until the next space, or the end.
public struct DraftChunker: Sendable, Equatable {
    private var held = ""
    private var started = false

    public init() {}

    /// Text that is ready to go into the field now. Often empty.
    public mutating func feed(_ delta: String) -> String {
        held += delta
        if !started {
            held = String(held.drop(while: \.isWhitespace))
            guard !held.isEmpty else { return "" }
            started = true
        }
        guard !held.hasSuffix(Self.emDash) else { return "" }
        held = Self.replacingEmDashes(held)

        // Cut at the start of the last run of whitespace: what follows may be
        // half a word, or the whitespace the answer ends with.
        guard var cut = held.lastIndex(where: \.isWhitespace) else { return "" }
        while cut > held.startIndex, held[held.index(before: cut)].isWhitespace {
            cut = held.index(before: cut)
        }
        let ready = String(held[..<cut])
        held = String(held[cut...])
        return ready
    }

    /// Whatever was held back, once the answer is complete, minus the
    /// whitespace it ended with.
    public mutating func finish() -> String {
        defer { held = "" }
        var rest = held
        while let last = rest.last, last.isWhitespace || String(last) == Self.emDash { rest.removeLast() }
        rest = Self.replacingEmDashes(rest)
        while let last = rest.last, last.isWhitespace { rest.removeLast() }
        return rest
    }

    static let emDash = "\u{2014}"

    static func replacingEmDashes(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\u2014\s*"#, with: ", ", options: .regularExpression)
    }
}
