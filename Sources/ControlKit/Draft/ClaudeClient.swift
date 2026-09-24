import Foundation

// MARK: Wire types

/// `POST /v1/messages`, reduced to what drafting uses: a system prompt in
/// blocks (so the stable part can be cached), one user turn, adaptive thinking,
/// an effort level, and always streamed.
struct ClaudeRequest: Encodable {
    struct TextBlock: Encodable {
        let type = "text"
        let text: String
        let cache_control: CacheControl?
    }

    struct CacheControl: Encodable {
        let type = "ephemeral"
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct Thinking: Encodable {
        let type = "adaptive"
    }

    struct OutputConfig: Encodable {
        let effort: String
    }

    let model: String
    let max_tokens: Int
    /// Both nil for Haiku 4.5, which takes neither adaptive thinking nor an
    /// effort level. Nil fields are left out of the body.
    let thinking: Thinking?
    let output_config: OutputConfig?
    let system: [TextBlock]
    let messages: [Message]
    let stream = true
}

/// One `data:` line of the event stream. Only three kinds matter: text
/// deltas, the closing `message_delta` with the stop reason, and `error`.
/// Thinking deltas arrive empty and are skipped with everything else.
struct ClaudeStreamEvent: Decodable {
    struct Delta: Decodable {
        let type: String?
        let text: String?
        let stop_reason: String?
    }

    struct Usage: Decodable {
        let input_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
        let output_tokens: Int?
    }

    struct Message: Decodable {
        let usage: Usage?
    }

    let type: String
    let delta: Delta?
    let error: ClaudeErrorBody.Detail?
    /// On `message_start`: the input side, counted once the prompt is read.
    let message: Message?
    /// On `message_delta`: running totals, output included.
    let usage: Usage?
}

/// What one reply cost, in tokens, and roughly in dollars.
public struct ClaudeUsage: Sendable, Equatable {
    public var inputTokens = 0
    public var cacheWriteTokens = 0
    public var cacheReadTokens = 0
    public var outputTokens = 0

    public init(inputTokens: Int = 0, cacheWriteTokens: Int = 0, cacheReadTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
    }

    /// Dollars per million tokens, input then output, at list price. A cache
    /// write costs 1.25 times input and a cache read a tenth of it.
    static let prices: [String: (input: Double, output: Double)] = [
        "claude-sonnet-5": (2, 10),
        "claude-haiku-4-5": (1, 5),
    ]

    /// An estimate from list prices, not a bill. Zero for a model not listed.
    public func dollars(for model: String) -> Double {
        guard let price = Self.prices[model] else { return 0 }
        let input = Double(inputTokens) + Double(cacheWriteTokens) * 1.25 + Double(cacheReadTokens) * 0.1
        return (input * price.input + Double(outputTokens) * price.output) / 1_000_000
    }

    mutating func merge(_ usage: ClaudeStreamEvent.Usage) {
        if let value = usage.input_tokens { inputTokens = value }
        if let value = usage.cache_creation_input_tokens { cacheWriteTokens = value }
        if let value = usage.cache_read_input_tokens { cacheReadTokens = value }
        if let value = usage.output_tokens { outputTokens = value }
    }
}

/// A failed reply: `{"type": "error", "error": {"type": "…", "message": "…"}}`.
struct ClaudeErrorBody: Decodable {
    struct Detail: Decodable {
        let type: String?
        let message: String?
    }

    let error: Detail?
}

// MARK: Errors

public enum ClaudeError: Error, LocalizedError, Equatable {
    case notConfigured
    case http(Int)
    /// A failure the service explained, in its own words.
    case api(status: Int, message: String)
    /// The model declined to write this one.
    case refused
    /// The reply hit the token cap.
    case truncated
    case empty
    /// The stream ended without saying why.
    case incomplete
    case transport(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Add your Claude key in Control's settings."
        case .http(401): "Claude didn't accept this key. Check it in Control's settings."
        case .http(429): "Too many requests right now. Try again in a moment."
        case .http(529): "Claude is busy right now. Try again in a moment."
        case let .http(status): "Claude returned an error (\(status))."
        case let .api(_, message): message
        case .refused: "Claude declined to answer this one."
        case .truncated: "The answer ran too long and was cut off."
        case .incomplete: "The connection closed before the answer finished."
        case .empty: "Claude sent back an empty answer."
        case let .transport(message): "Couldn't reach Claude: \(message)"
        case let .decoding(message): "Couldn't read Claude's reply: \(message)"
        }
    }
}

// MARK: Client

/// Talks to Claude's Messages API (`POST https://api.anthropic.com/v1/messages`),
/// streaming.
///
/// Raw HTTP because there is no official Swift SDK. Deliberately thin, like
/// `JevClient`: one POST, text out as it is written. What goes into the prompt
/// is `AnswerDrafter`'s job, and reading the event stream is
/// `ClaudeStreamParser`'s, which keeps both testable without a network.
public struct ClaudeClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    /// Sonnet over Haiku on purpose. A draft costs one or two cents either way,
    /// and these are answers the user submits under their own name: Sonnet
    /// sticks to the facts it was given and writes less like a template.
    public static let defaultModel = "claude-sonnet-5"
    /// For small judgements that nobody reads as prose, like whether an answer
    /// is worth remembering. A tenth of a cent a call.
    public static let fastModel = "claude-haiku-4-5"
    public static let apiVersion = "2023-06-01"
    /// A cap on the error body read from a failed request. It is a short JSON
    /// object; anything longer is not worth waiting for.
    static let maxErrorBodyBytes = 16 * 1024

    public var baseURL: URL
    public var apiKey: String
    public var model: String
    public var session: URLSession
    /// Told what each reply cost once it ends, whether or not it succeeded:
    /// a refusal or a cut-off answer is still billed.
    public var onUsage: (@Sendable (ClaudeUsage) -> Void)?

    public init(
        apiKey: String,
        baseURL: URL = ClaudeClient.defaultBaseURL,
        model: String = ClaudeClient.defaultModel,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.session = session
    }

    /// One system prompt in blocks, one user message; the reply's text, piece
    /// by piece as it is written.
    ///
    /// The stream finishes by throwing when the reply didn't end cleanly — a
    /// refusal, the token cap, a dropped connection — *after* yielding whatever
    /// text came first. Stop iterating and the request is cancelled.
    ///
    /// - Parameter cachedSystem: the stable part of the system prompt. It is
    ///   marked for caching, so a second draft within a few minutes — the next
    ///   question on the same application — reads it back at a tenth of the price.
    /// - Parameter effort: with adaptive thinking. Nil sends neither, which is
    ///   what Haiku 4.5 needs.
    /// - Parameter idleTimeout: the longest gap allowed between bytes. The
    ///   server sends keep-alive pings, so a long answer never trips it.
    func stream(
        system: String,
        cachedSystem: String,
        user: String,
        maxTokens: Int,
        effort: String?,
        idleTimeout: TimeInterval
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(
                        system: system, cachedSystem: cachedSystem, user: user,
                        maxTokens: maxTokens, effort: effort, idleTimeout: idleTimeout
                    )
                    let (bytes, response) = try await session.bytes(for: request)

                    if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= Self.maxErrorBodyBytes { break }
                        }
                        throw Self.error(status: http.statusCode, body: body)
                    }

                    var parser = ClaudeStreamParser()
                    defer { if parser.usage != ClaudeUsage() { onUsage?(parser.usage) } }
                    // `lines` drops the blank separator lines, which is fine: every
                    // `data:` line carries its own event type.
                    for try await line in bytes.lines {
                        if let text = try parser.consume(line) { continuation.yield(text) }
                    }
                    try parser.finish()
                    continuation.finish()
                } catch let error as ClaudeError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: ClaudeError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(
        system: String,
        cachedSystem: String,
        user: String,
        maxTokens: Int,
        effort: String?,
        idleTimeout: TimeInterval
    ) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ClaudeError.notConfigured }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.httpBody = try Self.encode(ClaudeRequest(
            model: model,
            max_tokens: maxTokens,
            thinking: effort.map { _ in .init() },
            output_config: effort.map { .init(effort: $0) },
            system: [
                .init(text: system, cache_control: nil),
                .init(text: cachedSystem, cache_control: .init()),
            ],
            messages: [.init(role: "user", content: user)]
        ))
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = idleTimeout
        return request
    }

    /// The whole reply, for short answers nobody watches arrive.
    func complete(
        system: String,
        cachedSystem: String,
        user: String,
        maxTokens: Int,
        effort: String?,
        idleTimeout: TimeInterval
    ) async throws -> String {
        var text = ""
        for try await piece in stream(system: system, cachedSystem: cachedSystem, user: user,
                                      maxTokens: maxTokens, effort: effort, idleTimeout: idleTimeout) {
            text += piece
        }
        return text
    }

    /// A minimal round trip, to check a key works before relying on it.
    public func checkConnection() async throws {
        let reply = stream(
            system: "Reply with the single word: ok",
            cachedSystem: "This is a connection check.",
            user: "Check.",
            maxTokens: 1024,
            effort: "low",
            idleTimeout: 20
        )
        for try await _ in reply {}
    }

    static func encode(_ request: ClaudeRequest) throws -> Data {
        do {
            return try JSONEncoder().encode(request)
        } catch {
            throw ClaudeError.decoding(error.localizedDescription)
        }
    }

    /// A failed request, in the service's own words where it gave some. The
    /// statuses a user can act on keep Control's wording, which says what to do.
    public static func error(status: Int, body: Data) -> ClaudeError {
        if [401, 429, 529].contains(status) { return .http(status) }
        if let message = (try? JSONDecoder().decode(ClaudeErrorBody.self, from: body))?.error?.message {
            return .api(status: status, message: message)
        }
        return .http(status)
    }
}

// MARK: Event stream

/// Reads the Messages API's server-sent events one line at a time.
///
/// Pure, so the tests can feed it recorded streams. Text comes out as it
/// arrives; how the reply ended is only known at `finish()`, which throws for
/// every ending that isn't a finished answer.
public struct ClaudeStreamParser: Sendable {
    public private(set) var stopReason: String?
    public private(set) var usage = ClaudeUsage()
    private var sawText = false

    public init() {}

    /// One line of the stream; the text it adds, if any.
    public mutating func consume(_ line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let json = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)

        let event: ClaudeStreamEvent
        do {
            event = try JSONDecoder().decode(ClaudeStreamEvent.self, from: Data(json.utf8))
        } catch {
            throw ClaudeError.decoding(error.localizedDescription)
        }

        if let reported = event.message?.usage { usage.merge(reported) }
        if let reported = event.usage { usage.merge(reported) }

        switch event.type {
        case "content_block_delta":
            guard event.delta?.type == "text_delta", let text = event.delta?.text, !text.isEmpty else { return nil }
            sawText = true
            return text
        case "message_delta":
            if let reason = event.delta?.stop_reason { stopReason = reason }
            return nil
        case "error":
            // Mid-stream failures arrive as an event on a 200 response.
            switch event.error?.type {
            case "overloaded_error": throw ClaudeError.http(529)
            case "rate_limit_error": throw ClaudeError.http(429)
            default: throw ClaudeError.api(status: 200, message: event.error?.message ?? "Claude reported an error.")
            }
        default:
            return nil
        }
    }

    /// How the reply ended, once the stream has closed.
    public func finish() throws {
        switch stopReason {
        case "refusal": throw ClaudeError.refused
        case "max_tokens": throw ClaudeError.truncated
        case nil: throw ClaudeError.incomplete
        default: if !sawText { throw ClaudeError.empty }
        }
    }
}
