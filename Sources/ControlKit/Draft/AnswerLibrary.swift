import Foundation

/// An answer Control drafted, as the user left it, and every question it has
/// answered. Kept so the same question on another form, another day, gets the
/// same answer instead of a new one.
public struct SavedAnswer: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Every wording it has answered, first first.
    public var questions: [String]
    /// The final text: the draft, or the user's edit of it.
    public var text: String
    public var site: String?
    public var updatedAt: Date

    public init(id: UUID = UUID(), questions: [String], text: String, site: String?, updatedAt: Date = Date()) {
        self.id = id
        self.questions = questions
        self.text = text
        self.site = site
        self.updatedAt = updatedAt
    }
}

/// Finding a saved answer for a new question. The exact match is local and
/// free; a reworded question is Jev's call (`AnswerReuse`), made over the
/// candidates this ranks.
public enum AnswerLibrary {
    /// The most Jev is asked to choose between, as for field matching.
    public static let maxCandidates = JevMatcher.maxCandidates

    /// The same question, give or take punctuation, case, and the "Required
    /// question" Google Forms appends to every label.
    public static func exactMatch(for question: String, in library: [SavedAnswer]) -> SavedAnswer? {
        let key = comparable(question)
        guard !key.isEmpty else { return nil }
        return library
            .sorted { $0.updatedAt > $1.updatedAt }
            .first { $0.questions.contains { comparable($0) == key } }
    }

    /// The saved answers most worth showing Jev, most similar question first.
    /// Similarity is shared content words, which is rough on purpose: Jev
    /// decides, and this only decides who is asked about when there are many.
    public static func candidates(for question: String, in library: [SavedAnswer]) -> [SavedAnswer] {
        let words = contentWords(question)
        let scored: [(answer: SavedAnswer, score: Double)] = library.map { answer in
            let best = answer.questions.map { overlap(words, contentWords($0)) }.max() ?? 0
            return (answer, best)
        }
        let ranked = scored.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.answer.updatedAt > rhs.answer.updatedAt
        }
        return ranked.prefix(maxCandidates).map(\.answer)
    }

    /// Whether a saved answer suits this box: within any stated limit, and not
    /// paragraphs pushed into a single line.
    public static func fits(_ text: String, in context: FieldContext) -> Bool {
        if let limit = LengthLimit.find(in: context), limit.isExceeded(by: text) { return false }
        if context.role == "AXTextField", text.contains("\n") || LengthLimit.wordCount(text) > 60 { return false }
        return true
    }

    static func comparable(_ question: String) -> String {
        let words = words(question)
        return words.filter { !["required", "question", "optional"].contains($0) }.joined(separator: " ")
    }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "about", "with", "at", "by", "is",
        "are", "was", "were", "be", "you", "your", "yourself", "us", "me", "my", "i", "we", "our", "do",
        "did", "does", "what", "why", "how", "which", "who", "when", "where", "tell", "please", "share",
        "describe", "that", "this", "it", "as", "any", "have", "has", "required", "question", "optional",
        "whats", "youre", "youve", "ive", "im",
    ]

    static func contentWords(_ text: String) -> Set<String> {
        Set(words(text).filter { !stopWords.contains($0) })
    }

    /// Apostrophes go before anything else, so "What's" and "whats" agree.
    private static func words(_ text: String) -> [String] {
        let joined = text.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
        return FieldContext.normalize(joined).split(separator: " ").map(String.init)
    }

    static func overlap(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let union = lhs.union(rhs)
        return union.isEmpty ? 0 : Double(lhs.intersection(rhs).count) / Double(union.count)
    }
}

/// Asks Jev whether a new question asks for the same answer as an earlier one.
///
/// Question text only crosses to Jev, never an answer: the earlier questions
/// are the criteria, as vault key descriptions are for field matching.
public enum AnswerReuse {
    static let questionKey = "same_answer"
    static let noMatch = JevMatcher.noMatchKey
    /// A reused answer goes in without asking, so the bar is high: a wrong
    /// reuse is an answer to a different question.
    public static let minimumConfidence = 0.75
    static let maxQuestionLength = 300

    public static func state(question: String, site: String?) -> [String: JSONValue] {
        var state: [String: JSONValue] = ["new_question": .string(String(question.prefix(maxQuestionLength)))]
        if let site { state["page_domain"] = .string(site) }
        return state
    }

    public static func questions(for candidates: [SavedAnswer]) -> [String: JevQuestion] {
        var criteria: [String: String] = [:]
        for candidate in candidates {
            criteria[candidate.id.uuidString] = String(candidate.questions.joined(separator: " / ").prefix(maxQuestionLength))
        }
        criteria[noMatch] = "None of these earlier questions asks for the same thing as the new question."
        return [
            questionKey: .choice(
                instructions: "A form asks the new question. Which earlier question asks for the same thing, so that an answer written for it would answer the new question just as well? Choose no_match unless it truly would.",
                criteria: criteria
            ),
        ]
    }

    /// The saved answer Jev picked, if it was confident enough.
    public static func pick(_ answers: [String: JevAnswer], from candidates: [SavedAnswer]) -> SavedAnswer? {
        guard let answer = answers[questionKey],
              let choice = answer.choice, choice != noMatch,
              (answer.confidence ?? 0) >= minimumConfidence
        else { return nil }
        return candidates.first { $0.id.uuidString == choice }
    }
}
