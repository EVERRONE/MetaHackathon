import Foundation

/// Client for the Pip Worker. Holds the app token; the Meta key never reaches the device.
public struct PipClient: Sendable {
    public var baseURL: URL
    public var token: String
    public var session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Stable bytes, so the cached prompt prefix stays identical between turns.
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// A JSON POST to the Worker with the app token.
    func request(_ path: String) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 60
        return r
    }

    static func check(_ response: URLResponse, body: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            struct Envelope: Decodable { struct E: Decodable { var code: String; var message: String }; var error: E }
            let e = body.flatMap { try? JSONDecoder().decode(Envelope.self, from: $0) }
            throw WorkerError(status: http.statusCode, code: e?.error.code ?? "http_\(http.statusCode)", message: e?.error.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }

    public func segment(_ body: SegmentRequest) async throws -> SegmentResponse {
        var r = request("v1/segment")
        r.httpBody = try Self.encoder.encode(body)
        let (data, response) = try await session.data(for: r)
        try Self.check(response, body: data)
        return try JSONDecoder().decode(SegmentResponse.self, from: data)
    }

    /// Speech for one sentence from the Worker's ElevenLabs route: 24 kHz 16-bit mono PCM plus the
    /// start time of every character (times run from the start of the sentence).
    /// One piece of a sentence's speech as it streams in: 16-bit PCM and the start times of the
    /// characters it covers (seconds from the start of the sentence).
    public struct SpeechChunk: Sendable {
        public var pcm: Data
        public var characters: [String]
        public var starts: [Double]
    }

    /// The same speech as `speak`, piece by piece as the Worker streams it, so playback can start
    /// with the first piece instead of after the whole sentence.
    public func speakStream(text: String, voice: String, language: String?) -> AsyncThrowingStream<SpeechChunk, Error> {
        struct Chunk: Decodable {
            struct Alignment: Decodable {
                var characters: [String]
                var character_start_times_seconds: [Double]
            }
            var audio_base64: String?
            var alignment: Alignment?
        }
        var r = request("v1/speak")
        var body: [String: String] = ["text": text, "voice": voice]
        if let language { body["language"] = language }
        r.httpBody = try? JSONEncoder().encode(body)
        r.timeoutInterval = 20
        let request = r, session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await b in bytes { data.append(b) }
                        try Self.check(response, body: data)
                    }
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        guard let chunk = try? decoder.decode(Chunk.self, from: Data(line.utf8)) else { continue }
                        let pcm = chunk.audio_base64.flatMap { Data(base64Encoded: $0) } ?? Data()
                        continuation.yield(SpeechChunk(pcm: pcm, characters: chunk.alignment?.characters ?? [],
                                                       starts: chunk.alignment?.character_start_times_seconds ?? []))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func speak(text: String, voice: String, language: String?) async throws -> SpokenAudio {
        struct Chunk: Decodable {
            struct Alignment: Decodable {
                var characters: [String]
                var character_start_times_seconds: [Double]
            }
            var audio_base64: String?
            var alignment: Alignment?
        }
        var r = request("v1/speak")
        var body: [String: String] = ["text": text, "voice": voice]
        if let language { body["language"] = language }
        r.httpBody = try JSONEncoder().encode(body)
        r.timeoutInterval = 20
        let (bytes, response) = try await session.bytes(for: r)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var data = Data()
            for try await b in bytes { data.append(b) }
            try Self.check(response, body: data)
        }
        var out = SpokenAudio(pcm: Data(), characters: [], starts: [])
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard let chunk = try? decoder.decode(Chunk.self, from: Data(line.utf8)) else { continue }
            if let b64 = chunk.audio_base64, let pcm = Data(base64Encoded: b64) { out.pcm.append(pcm) }
            if let a = chunk.alignment {
                out.characters += a.characters
                out.starts += a.character_start_times_seconds
            }
        }
        return out
    }

    /// A non-streaming Responses API call (web search, PDFs by URL); returns the output text.
    public func responsesText(_ body: JSONValue) async throws -> String {
        struct Response: Decodable {
            struct Item: Decodable {
                struct Content: Decodable { var type: String?; var text: String? }
                var type: String?
                var content: [Content]?
            }
            var output: [Item]?
        }
        var r = request("v1/responses")
        r.httpBody = try Self.encoder.encode(body)
        r.timeoutInterval = 180
        let (data, response) = try await session.data(for: r)
        try Self.check(response, body: data)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return (decoded.output ?? []).filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }.filter { $0.type == "output_text" }
            .compactMap(\.text).joined(separator: "\n")
    }

    /// What a link really answers with, after redirects.
    public struct SourceCheck: Decodable, Sendable {
        public var ok: Bool
        public var pdf: Bool?
        public var finalUrl: String?
        public var host: String?
    }

    /// Whether a link really answers with a PDF or a web page, and where it ends up.
    public func sourceCheck(_ url: String) async throws -> SourceCheck {
        var r = request("v1/source-check")
        r.httpBody = try JSONEncoder().encode(["url": url])
        let (data, response) = try await session.data(for: r)
        try Self.check(response, body: data)
        return try JSONDecoder().decode(SourceCheck.self, from: data)
    }

    /// Streams a chat completion as text deltas, a finish reason and the usage.
    public func chatStream(_ body: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body = body
                    body.stream = true
                    var r = request("v1/chat")
                    r.httpBody = try Self.encoder.encode(body)
                    r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: r)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await b in bytes { data.append(b) }
                        try Self.check(response, body: data)
                    }
                    let decoder = ChatChunkDecoder()
                    for try await line in bytes.lines {
                        for event in decoder.events(forLine: line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Non-streaming completion, for structured output (procedure compiler, checks).
    public func chat(_ body: ChatRequest) async throws -> (text: String, usage: ChatUsage?) {
        struct Response: Decodable {
            struct Choice: Decodable { struct M: Decodable { var content: String? }; var message: M }
            var choices: [Choice]
            var usage: ChatUsage?
        }
        var body = body
        body.stream = false
        var r = request("v1/chat")
        r.httpBody = try Self.encoder.encode(body)
        r.timeoutInterval = 120
        let (data, response) = try await session.data(for: r)
        try Self.check(response, body: data)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return (decoded.choices.first?.message.content ?? "", decoded.usage)
    }
}
