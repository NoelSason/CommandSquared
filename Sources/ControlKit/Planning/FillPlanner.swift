import Foundation

/// Decides what a fill does, without touching a window.
///
/// Three of the worst bugs Control has shipped lived in this logic while it sat
/// in the app target, where nothing could test it: cycling walked the entire
/// vault, the picker collapsed to a single row, and a candidate merely passed
/// through while cycling got recorded as a deliberate choice. None of that needs
/// an `AXUIElement` to decide — only to carry out.
public enum FillPlanner {
    /// How long after a fill a second trigger means "wrong one, try the next"
    /// rather than "fill this again". Long enough to read the field and react.
    public static let cycleWindow: TimeInterval = 5.0

    // MARK: Candidate lists

    /// What a second press cycles through: only keys that actually scored for
    /// this field.
    ///
    /// Appending the rest of the vault here is the bug that let an email box
    /// cycle into a date of birth. Cycling is for "you got the right *kind* of
    /// thing, wrong one"; anything broader belongs in the picker.
    public static func cycleList(for result: MatchResult) -> [String] {
        var keys = [result.key]
        var seen = Set(keys)
        for alternative in result.alternatives where seen.insert(alternative.key).inserted {
            keys.append(alternative.key)
        }
        return keys
    }

    /// What the picker lists: the plausible candidates first, then everything
    /// else that holds a value.
    ///
    /// The picker is the escape hatch and must always offer a way out — including
    /// out of a wrong remembered answer. Narrowing it to the scored candidates
    /// left exactly one row on screen and no way to correct it.
    public static func pickerList(startingWith keys: [String], allFillable: [String]) -> [String] {
        var ordered = keys
        var seen = Set(ordered)
        for key in allFillable where seen.insert(key).inserted {
            ordered.append(key)
        }
        return ordered
    }

    // MARK: Repeat presses

    /// What Control did last, kept so a second press can be interpreted.
    public struct LastFill: Sendable, Equatable {
        public var signature: String
        public var ranked: [String]
        public var index: Int
        public var insertedText: String
        public var at: Date

        public init(signature: String, ranked: [String], index: Int, insertedText: String, at: Date) {
            self.signature = signature
            self.ranked = ranked
            self.index = index
            self.insertedText = insertedText
            self.at = at
        }
    }

    public enum RepeatAction: Sendable, Equatable {
        /// Treat as a fresh fill.
        case fresh
        /// Replace the last value with this one.
        case cycle(to: String, index: Int)
        /// Ran out of plausible candidates — show the full list instead of wrapping.
        case exhausted
    }

    /// Decides whether this press continues the last fill.
    ///
    /// `fieldValue` is what the field holds right now. If Control's last insertion
    /// is no longer the tail of it, the user has edited since and a backspace run
    /// would eat their text — so this is deliberately conservative.
    public static func repeatAction(
        after last: LastFill?,
        signature: String,
        fieldValue: String?,
        now: Date = Date()
    ) -> RepeatAction {
        guard let last,
              last.signature == signature,
              now.timeIntervalSince(last.at) < cycleWindow,
              !last.ranked.isEmpty,
              let fieldValue,
              fieldValue.hasSuffix(last.insertedText)
        else { return .fresh }

        let next = last.index + 1
        guard next < last.ranked.count else { return .exhausted }
        return .cycle(to: last.ranked[next], index: next)
    }

    // MARK: Learning

    /// Whether an outcome should be recorded as something the user *named*.
    ///
    /// Only an explicit selection counts. Stopping on a candidate while cycling
    /// might just mean you gave up looking, and treating that as deliberate is
    /// how wrong answers got locked in permanently — protected entries are not
    /// overwritten by better evidence later.
    public static func isDeliberate(_ source: MatchSource) -> Bool {
        switch source {
        case .manual: true
        case .cache, .local, .jev: false
        }
    }

    // MARK: Presentation

    public static func hint(for result: MatchResult) -> String? {
        switch result.source {
        case .cache: "Remembered from last time"
        case .jev: "Jev's best guess — \(Int(result.confidence * 100))% confident"
        case .local, .manual: nil
        }
    }
}
