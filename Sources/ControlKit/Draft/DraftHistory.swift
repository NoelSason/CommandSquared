import Foundation

/// The drafts Control wrote recently, so the next question on the same
/// application can steer clear of stories already used, and "press again" knows
/// what the user passed on.
///
/// In memory only, and short-lived: it describes one sitting at one form.
public struct DraftHistory: Sendable {
    public struct Entry: Sendable, Equatable {
        public let question: String
        public let text: String
        /// The page's host, or the app's bundle ID outside a browser.
        public let site: String
        /// `FieldContext.signature`: which box it went in.
        public let field: String
        public let at: Date
        /// The saved answer it is, so one form never gets the same saved
        /// answer twice.
        public let savedAnswer: UUID?

        public init(question: String, text: String, site: String, field: String, at: Date = Date(), savedAnswer: UUID? = nil) {
            self.question = question
            self.text = text
            self.site = site
            self.field = field
            self.at = at
            self.savedAnswer = savedAnswer
        }
    }

    /// Long enough to cover filling in one application, with breaks.
    static let window: TimeInterval = 2 * 60 * 60
    /// The most recent few are plenty to avoid repeating a story.
    static let maxOthers = 6

    public private(set) var entries: [Entry] = []

    public init() {}

    /// A newer draft for the same box replaces the older one.
    public mutating func record(_ entry: Entry) {
        entries.removeAll { $0.field == entry.field || entry.at.timeIntervalSince($0.at) > Self.window }
        entries.append(entry)
    }

    /// Drafts for the *other* questions on this site, newest first.
    public func others(on site: String, excluding field: String, now: Date = Date()) -> [Entry] {
        entries
            .filter { $0.site == site && $0.field != field && now.timeIntervalSince($0.at) <= Self.window }
            .reversed()
            .prefix(Self.maxOthers)
            .map { $0 }
    }

    public static func site(for context: FieldContext) -> String {
        context.domain ?? context.bundleID
    }
}

/// A length limit stated in or around a question: "(250 words)", "Max 1000
/// characters", "150-200 words".
public struct LengthLimit: Sendable, Equatable {
    public enum Unit: Sendable, Equatable {
        case words
        case characters
    }

    public let value: Int
    public let unit: Unit

    public init(value: Int, unit: Unit) {
        self.value = value
        self.unit = unit
    }

    /// A number, then the unit. In a range the second number is the one met,
    /// which is the upper bound. A minimum ("at least 100 words") is no limit.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(at least|minimum|min\.?|no fewer than)?\s*(\d{1,3}(?:,\d{3})+|\d+)\s*(?:-\s*)?(words?|characters?|chars?)\b"#,
        options: .caseInsensitive
    )

    /// The field's own texts first, then the text around it.
    public static func find(in context: FieldContext) -> LengthLimit? {
        let texts = [context.label, context.helpText, context.placeholder].compactMap { $0 } + context.nearbyText
        for text in texts {
            if let limit = parse(text) { return limit }
        }
        return nil
    }

    static func parse(_ text: String) -> LengthLimit? {
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: range).reversed() {
            guard match.range(at: 1).location == NSNotFound,
                  let numberRange = Range(match.range(at: 2), in: text),
                  let unitRange = Range(match.range(at: 3), in: text),
                  let value = Int(text[numberRange].replacingOccurrences(of: ",", with: "")),
                  value > 0
            else { continue }
            let unit: Unit = text[unitRange].lowercased().hasPrefix("w") ? .words : .characters
            return LengthLimit(value: value, unit: unit)
        }
        return nil
    }

    public func count(_ text: String) -> Int {
        switch unit {
        case .words: Self.wordCount(text)
        case .characters: text.count
        }
    }

    public func isExceeded(by text: String) -> Bool {
        count(text) > value
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
