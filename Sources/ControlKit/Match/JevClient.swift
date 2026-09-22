import Foundation

// MARK: Questions

/// A single typed question. Jev evaluates every question in a request in parallel
/// against the same state, so asking two costs about the same as asking one.
public enum JevQuestion: Encodable, Sendable {
    case choice(instructions: String, criteria: [String: String])
    case score(instructions: String, criteria: [String])
    case noul(instructions: String)

    private enum CodingKeys: String, CodingKey {
        case type, instructions, criteria
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .choice(instructions, criteria):
            try container.encode("choice", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            try container.encode(criteria, forKey: .criteria)
        case let .score(instructions, criteria):
            try container.encode("score", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            try container.encode(criteria, forKey: .criteria)
        case let .noul(instructions):
            try container.encode("noul", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
        }
    }
}

// MARK: Answers

public struct JevAnswer: Decodable, Sendable, Equatable {
    public let choice: String?
    public let score: String?
    public let noul: Double?
    public let confidence: Double?
    public let probabilities: [String: Double]?

    private enum CodingKeys: String, CodingKey {
        case choice, score, noul, confidence, probabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        choice = try container.decodeIfPresent(String.self, forKey: .choice)
        noul = try container.decodeIfPresent(Double.self, forKey: .noul)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        probabilities = try container.decodeIfPresent([String: Double].self, forKey: .probabilities)

        // `score` comes back as a rubric level, which may be a label or an index.
        if let label = try? container.decodeIfPresent(String.self, forKey: .score) {
            score = label
        } else if let index = try? container.decodeIfPresent(Double.self, forKey: .score) {
            score = String(index)
        } else {
            score = nil
        }
    }

    public init(
        choice: String? = nil,
        score: String? = nil,
        noul: Double? = nil,
        confidence: Double? = nil,
        probabilities: [String: Double]? = nil
    ) {
        self.choice = choice
        self.score = score
        self.noul = noul
        self.confidence = confidence
        self.probabilities = probabilities
    }
}

// MARK: Wire types

struct JevRequest: Encodable {
    let model: String
    let state: [String: JSONValue]
    let questions: [String: JevQuestion]
}

struct JevEnvelope: Decodable {
    let code: Int
    let message: String?
    let data: JevDecisionData?
}

struct JevDecisionData: Decodable {
    let answers: [String: JevAnswer]?
    // Present on the preset endpoints (tool-guard, route, …), absent on native decisions.
    let decision: String?
    let confidence: Double?
    let probabilities: [String: Double]?
    let guidance: String?
}

// MARK: Errors

public enum JevError: Error, LocalizedError {
    case notConfigured
    case bodyTooLarge(Int)
    case http(Int)
    case api(code: Int, message: String)
    case transport(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "No Jev API key is set."
        case let .bodyTooLarge(bytes): "Request body is \(bytes) bytes, over Jev's 32 KiB limit."
        case let .http(status): "Jev returned HTTP \(status)."
        case let .api(code, message): "Jev error \(code): \(message)"
        case let .transport(message): "Could not reach Jev: \(message)"
        case let .decoding(message): "Could not read Jev's response: \(message)"
        }
    }
}

// MARK: Client

/// Talks to Jev's native decisions endpoint.
///
/// Deliberately thin: one POST, typed answers out. Nothing here knows what a
/// vault is — building the questions and reading the confidence is `JevMatcher`'s
/// job, which keeps the network layer testable against recorded JSON.
public struct JevClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://www.jevai.org")!
    public static let defaultModel = "typesafe-ai/jev"
    /// Documented request cap.
    public static let maxBodyBytes = 32 * 1024

    public var baseURL: URL
    public var apiKey: String
    public var model: String
    public var session: URLSession

    public init(
        apiKey: String,
        baseURL: URL = JevClient.defaultBaseURL,
        model: String = JevClient.defaultModel,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.session = session
    }

    public func decide(
        state: [String: JSONValue],
        questions: [String: JevQuestion]
    ) async throws -> [String: JevAnswer] {
        guard !apiKey.isEmpty else { throw JevError.notConfigured }

        let payload = JevRequest(model: model, state: state, questions: questions)
        let body: Data
        do {
            body = try JSONEncoder().encode(payload)
        } catch {
            throw JevError.decoding(error.localizedDescription)
        }
        guard body.count <= Self.maxBodyBytes else {
            throw JevError.bodyTooLarge(body.count)
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/decisions"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // The picker is already on screen by the time this runs; a slow answer is
        // worse than no answer, so fail fast to the manual list.
        request.timeoutInterval = 6

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw JevError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            // Jev explains itself in the body — "Invalid or missing Jev API key"
            // is far more use than "HTTP 401". Read it before giving up.
            if let envelope = try? JSONDecoder().decode(JevEnvelope.self, from: data),
               let message = envelope.message {
                throw JevError.api(code: envelope.code, message: message)
            }
            throw JevError.http(http.statusCode)
        }

        return try Self.parse(data)
    }

    /// A minimal round trip, to check a key works before relying on it.
    public func checkConnection() async throws {
        _ = try await decide(
            state: ["field_label": .string("Email address")],
            questions: [
                "field": .choice(
                    instructions: "Which stored personal-data field is this input asking for?",
                    criteria: ["email_personal": "The user's personal email address",
                               "no_match": "None of the stored fields fit this input."]
                ),
            ]
        )
    }

    /// Split out so tests can exercise it against recorded responses.
    public static func parse(_ data: Data) throws -> [String: JevAnswer] {
        let envelope: JevEnvelope
        do {
            envelope = try JSONDecoder().decode(JevEnvelope.self, from: data)
        } catch {
            throw JevError.decoding(error.localizedDescription)
        }
        guard envelope.code == 0 else {
            throw JevError.api(code: envelope.code, message: envelope.message ?? "unknown")
        }
        return envelope.data?.answers ?? [:]
    }
}
