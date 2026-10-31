import Foundation

/// OpenAI-style chat request for Muse Spark, sent through the Worker.
public struct ChatRequest: Encodable, Sendable {
    public enum ReasoningEffort: String, Encodable, Sendable { case minimal, low, medium, high, max }

    public var model = "muse-spark-1.3"
    public var messages: [ChatMessage]
    public var stream: Bool
    public var reasoningEffort: ReasoningEffort
    /// Routes requests with the same stable prefix to the same cache.
    public var promptCacheKey: String?
    public var maxCompletionTokens: Int?
    public var responseFormat: ResponseFormat?

    public init(messages: [ChatMessage], stream: Bool = true, reasoningEffort: ReasoningEffort = .minimal, promptCacheKey: String? = nil, maxCompletionTokens: Int? = nil, responseFormat: ResponseFormat? = nil) {
        self.messages = messages
        self.stream = stream
        self.reasoningEffort = reasoningEffort
        self.promptCacheKey = promptCacheKey
        self.maxCompletionTokens = maxCompletionTokens
        self.responseFormat = responseFormat
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, stream
        case reasoningEffort = "reasoning_effort"
        case promptCacheKey = "prompt_cache_key"
        case maxCompletionTokens = "max_completion_tokens"
        case responseFormat = "response_format"
    }
}

/// `response_format: { type: "json_schema", json_schema: { name, strict, schema } }`.
public struct ResponseFormat: Encodable, Sendable {
    public var name: String
    public var schema: JSONValue

    public init(name: String, schema: JSONValue) {
        self.name = name
        self.schema = schema
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode("json_schema", forKey: AnyKey("type"))
        try c.encode(JSONValue.object(["name": .string(name), "strict": .bool(true), "schema": schema]), forKey: AnyKey("json_schema"))
    }
}

public struct ChatMessage: Encodable, Sendable, Equatable {
    public enum Role: String, Encodable, Sendable { case system, user, assistant }

    public enum Part: Encodable, Sendable, Equatable {
        case text(String)
        case imageJPEG(Data)

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            switch self {
            case .text(let t):
                try c.encode("text", forKey: AnyKey("type"))
                try c.encode(t, forKey: AnyKey("text"))
            case .imageJPEG(let data):
                try c.encode("image_url", forKey: AnyKey("type"))
                try c.encode(["url": "data:image/jpeg;base64," + data.base64EncodedString()], forKey: AnyKey("image_url"))
            }
        }
    }

    public var role: Role
    public var parts: [Part]

    public init(role: Role, parts: [Part]) {
        self.role = role
        self.parts = parts
    }

    public static func system(_ text: String) -> ChatMessage { ChatMessage(role: .system, parts: [.text(text)]) }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, parts: [.text(text)]) }
    public static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, parts: [.text(text)]) }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(role, forKey: AnyKey("role"))
        // Plain text stays a string: it keeps the cached prefix byte-identical across turns.
        if parts.count == 1, case .text(let t) = parts[0] {
            try c.encode(t, forKey: AnyKey("content"))
        } else {
            try c.encode(parts, forKey: AnyKey("content"))
        }
    }
}

public struct ChatUsage: Decodable, Equatable, Sendable {
    public struct PromptDetails: Decodable, Equatable, Sendable {
        public var cachedTokens: Int?
        enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
    }

    public var promptTokens: Int
    public var completionTokens: Int
    public var promptTokensDetails: PromptDetails?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case promptTokensDetails = "prompt_tokens_details"
    }
}

public enum ChatStreamEvent: Equatable, Sendable {
    case delta(String)
    case finished(reason: String?)
    case usage(ChatUsage)
}

/// Decodes the `data:` payloads of a chat completion SSE stream.
public struct ChatChunkDecoder: Sendable {
    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { var content: String? }
            var delta: Delta?
            var finishReason: String?
            enum CodingKeys: String, CodingKey { case delta, finishReason = "finish_reason" }
        }
        var choices: [Choice]?
        var usage: ChatUsage?
    }

    public init() {}

    /// Events for one SSE line; ignores comments, blank lines and `[DONE]`.
    public func events(forLine line: String) -> [ChatStreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload.hasPrefix("{"), let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { return [] }
        var out: [ChatStreamEvent] = []
        for choice in chunk.choices ?? [] {
            if let text = choice.delta?.content, !text.isEmpty { out.append(.delta(text)) }
            if let reason = choice.finishReason { out.append(.finished(reason: reason)) }
        }
        if let usage = chunk.usage { out.append(.usage(usage)) }
        return out
    }
}

/// A coding key for hand-written containers.
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Minimal JSON value, for schemas and free-form payloads.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
