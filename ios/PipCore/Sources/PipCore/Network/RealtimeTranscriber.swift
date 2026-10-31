import Foundation

/// Live speech recognition through the Worker's `/v1/asr` relay (Muse Voice Transcribe, endpointing).
///
/// Send 16-bit mono PCM continuously, silence included: the service closes a session that stops
/// receiving audio. Events report when speech starts, the growing transcript, and each finished turn.
public final class RealtimeTranscriber: NSObject, @unchecked Sendable, URLSessionWebSocketDelegate {
    public enum Event: Equatable, Sendable {
        case ready
        case speechStart(turn: Int)
        case partial(String)
        case speechEnd(turn: Int)
        /// A finished turn, punctuated.
        case final(turn: Int, text: String)
        case error(String)
        case closed(code: Int, reason: String)
    }

    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let request: URLRequest
    private let handshake: String
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var open = false
    private var currentTurn = 0
    /// Audio captured before the service acknowledged the handshake (at most 10 s).
    private var backlog: [Data] = []
    private var backlogBytes = 0

    /// `sampleRate` is 16 000 or 24 000.
    public init(baseURL: URL, token: String, sampleRate: Int = 16_000, languages: [String] = ["English", "Dutch"], keywords: [String] = []) {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/asr"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        var r = URLRequest(url: components.url!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request = r
        var hs: [String: Any] = [
            "audioEncoding": sampleRate == 24_000 ? "PCM_24KHZ" : "PCM_16KHZ",
            "mode": "ENDPOINTING",
            "partialMode": "CUMULATIVE",
            "languageBias": languages,
        ]
        if !keywords.isEmpty { hs["keywords"] = keywords }
        handshake = String(data: try! JSONSerialization.data(withJSONObject: hs), encoding: .utf8)!
        (events, continuation) = AsyncStream<Event>.makeStream()
        super.init()
    }

    public func connect() {
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let t = s.webSocketTask(with: request)
        lock.lock(); session = s; task = t; lock.unlock()
        t.resume()
        t.send(.string(handshake)) { [weak self] error in
            if let error { self?.continuation.yield(.error("handshake: \(error.localizedDescription)")) }
        }
        receive()
    }

    /// Audio sent before the handshake is acknowledged is held and flushed once the session is open.
    public func send(pcm: Data) {
        lock.lock()
        let t = task
        guard open, let t else {
            if task != nil, backlogBytes < 320_000 {
                backlog.append(pcm)
                backlogBytes += pcm.count
            }
            lock.unlock()
            return
        }
        lock.unlock()
        t.send(.data(pcm)) { _ in }
    }

    /// Ends input; the service flushes the last turn and closes.
    public func finish() {
        lock.lock(); let t = task; lock.unlock()
        t?.send(.string(#"{"type":"endStream"}"#)) { _ in }
    }

    /// Closes the session and ends `events`, so whoever listens is released.
    public func close() {
        lock.lock(); let t = task; task = nil; open = false; lock.unlock()
        t?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        continuation.finish()
    }

    private func receive() {
        lock.lock(); let t = task; lock.unlock()
        t?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.handle(text)
                self.receive()
            case .success(.data):
                self.receive()
            case .success:
                self.receive()
            case .failure(let error):
                self.lock.lock(); let wasOpen = self.task != nil; self.task = nil; self.open = false; self.lock.unlock()
                if wasOpen { self.continuation.yield(.closed(code: -1, reason: error.localizedDescription)) }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        guard let type = json["type"] as? String else {
            // The acknowledgement is the only frame without a type.
            // Flush the held audio before opening, inside the lock, so live audio cannot overtake it.
            lock.lock()
            let accepted = json["sessionId"] != nil
            if accepted, let t = task {
                for chunk in backlog { t.send(.data(chunk)) { _ in } }
            }
            backlog = []
            backlogBytes = 0
            open = accepted
            lock.unlock()
            continuation.yield(accepted ? .ready : .error("handshake refused: \(text.prefix(200))"))
            return
        }
        switch type {
        case "speechStart":
            currentTurn = json["turnId"] as? Int ?? currentTurn + 1
            continuation.yield(.speechStart(turn: currentTurn))
        case "transcript":
            if let t = json["transcript"] as? String { continuation.yield(.partial(t.trimmingCharacters(in: .whitespaces))) }
        case "speechEnd":
            continuation.yield(.speechEnd(turn: json["turnId"] as? Int ?? currentTurn))
        case "speechComplete":
            let t = (json["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            continuation.yield(.final(turn: json["turnId"] as? Int ?? currentTurn, text: t))
        case "error":
            continuation.yield(.error(json["message"] as? String ?? text))
        default:
            break
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // Report a close once, whether it is seen here or as a receive failure first.
        lock.lock(); let wasOpen = task != nil; task = nil; open = false; lock.unlock()
        if wasOpen { continuation.yield(.closed(code: closeCode.rawValue, reason: reason.flatMap { String(data: $0, encoding: .utf8) } ?? "")) }
    }
}
