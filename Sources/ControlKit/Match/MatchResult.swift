import Foundation

public struct ScoredKey: Sendable, Equatable, Hashable {
    public let key: String
    public let score: Double

    public init(key: String, score: Double) {
        self.key = key
        self.score = score
    }
}

public enum MatchSource: String, Sendable, Codable {
    case cache
    case local
    case jev
    case manual
}

public struct MatchResult: Sendable, Equatable {
    public let key: String
    public let confidence: Double
    public let source: MatchSource
    /// Ranked alternatives, best first, for the picker. Excludes `key`.
    public let alternatives: [ScoredKey]
    /// Whether the target field is asking for financial or government-ID data.
    /// Set by Jev's `noul` question, or by a local heuristic when Jev wasn't called.
    public let looksSensitive: Bool

    public init(
        key: String,
        confidence: Double,
        source: MatchSource,
        alternatives: [ScoredKey] = [],
        looksSensitive: Bool = false
    ) {
        self.key = key
        self.confidence = confidence
        self.source = source
        self.alternatives = alternatives
        self.looksSensitive = looksSensitive
    }
}

/// What the app should actually do with a match. The thresholds live in
/// `MatchThresholds` so they are tunable in one place.
public enum FillDecision: Sendable, Equatable {
    /// Confident and harmless — insert, then show an undoable toast.
    case insert(MatchResult)
    /// Plausible, or sensitive. Show the HUD with this preselected.
    case confirm(MatchResult)
    /// No usable guess. Show the full searchable picker, optionally explaining why.
    case choose(ranked: [ScoredKey], hint: String?)
    /// Refused before matching ran.
    case blocked(BlockReason)
}

public enum BlockReason: String, Sendable, Equatable, Error {
    case secureField
    case deniedApp
    case noFocusedField
    case notEditable
    case emptyVault
    case unreadableField

    public var message: String {
        switch self {
        case .secureField: "Control never fills password fields."
        case .deniedApp: "Control is turned off for this app or site."
        case .noFocusedField: "No text field is focused."
        case .notEditable: "That isn't a text field Control can fill."
        case .emptyVault: "Nothing saved yet — add your details in Control's settings."
        case .unreadableField: "Couldn't read a label for this field."
        }
    }
}

public enum MatchThresholds {
    /// At or above this, fill without asking.
    ///
    /// Deliberately low. Asking is expensive — it costs a decision and two
    /// keystrokes every time — while being wrong is cheap, because a second press
    /// swaps in the next candidate and the correction is remembered forever. So
    /// the system guesses, and learns from being corrected, rather than hedging.
    public static let autoInsert = 0.55
    /// At or above this, preselect in the picker. Below it, open the full list.
    public static let confirm = 0.30
    /// Jev `noul` at or above this means treat the field as sensitive.
    public static let sensitive = 0.50
}
