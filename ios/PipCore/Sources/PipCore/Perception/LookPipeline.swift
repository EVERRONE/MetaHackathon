import CoreGraphics
import Foundation

/// The decision the validator made about one tag, kept for the "How Pip sees" trace.
public struct CueTrace: Equatable, Sendable {
    public var raw: String
    public var decision: CueValidator.Decision
}

public struct LookSummary: Sendable {
    /// Spark's full text, tags included.
    public var rawText: String
    public var usage: ChatUsage?
    public var firstTokenSeconds: Double?
    public var firstSentenceSeconds: Double?
    public var totalSeconds: Double
}

public enum LookEvent: Sendable {
    /// Spark named something to point at; grounding has started.
    case target(id: Int, spec: TargetSpec)
    /// The exact outline for a target (full-frame pixels, `id` = the mark), or nil if not found.
    case grounded(id: Int, instance: SegmentInstance?, method: String, seconds: Double)
    /// Marks mode only: every instance, numbered, and the image Spark sees them on.
    case segmented(SegmentResponse, markedJPEG: Data)
    /// A sentence ready to speak, with only the cues that passed validation.
    case sentence(SpokenSentence, traces: [CueTrace])
    case sideChannel(Cue)
    case invalidTag(CueError)
    case finished(LookSummary)
}

public struct LookRequest: Sendable {
    public var frame: CGImage
    /// Marks mode: fixed SAM phrases, every instance numbered (used by the eval).
    public var prompts: [String]?
    public var goal: String?
    public var step: PipPrompt.Step?
    public var facts: [String]
    public var history: [ChatMessage]
    public var utterance: String

    public init(frame: CGImage, prompts: [String]? = nil, goal: String? = nil, step: PipPrompt.Step? = nil, facts: [String] = [], history: [ChatMessage] = [], utterance: String) {
        self.frame = frame
        self.prompts = prompts
        self.goal = goal
        self.step = step
        self.facts = facts
        self.history = history
        self.utterance = utterance
    }
}

/// One "look", in a single streamed Spark call.
///
/// Spark speaks right away and points by position, object kind and printed text. Each target is
/// grounded in parallel (SAM in the region + on-device text recognition). A sentence is released
/// only once its targets are grounded, so a cue is never shown late or on a guess; Spark's first
/// sentence carries no cue, which covers the grounding time.
public struct LookPipeline: Sendable {
    public var client: PipClient
    public var validator: CueValidator
    public var language: String
    /// How long a finished sentence may wait for its targets before it is spoken without them.
    public var groundingTimeout: TimeInterval = 8.0
    /// Muse Wonder: on real keyboards Spark answered from PC habit at every reasoning level; Wonder
    /// read the device correctly at the lowest level, about one second slower (spike-results, day 1).
    public var model = "muse-wonder-1.0"
    public var effort: ChatRequest.ReasoningEffort = .minimal

    public init(client: PipClient, validator: CueValidator = CueValidator(), language: String = "English") {
        self.client = client
        self.validator = validator
        self.language = language
    }

    var promptCacheKey: String { "pip-\(PipPrompt.version)-\(model)-\(language.lowercased())" }

    public func run(_ request: LookRequest) -> AsyncThrowingStream<LookEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await perform(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum Input: Sendable {
        case chat(ChatStreamEvent)
        case chatEnded(String?)
        case grounded(Int, GroundingResult)
        case tick
    }

    private func perform(_ request: LookRequest, emit: (LookEvent) -> Void) async throws {
        let t0 = Date()
        func since(_ t: Date) -> Double { Date().timeIntervalSince(t) }
        let frame = request.frame
        guard let context = SetOfMarks.resize(frame, maxSide: 1280).flatMap({ SetOfMarks.jpeg($0, quality: 0.8) }) else { throw LookError.encoding }

        var marks: [Int: MarkInfo] = [:]
        var resolved = Set<Int>()
        let message: ChatMessage
        let system: String

        if let prompts = request.prompts {
            guard let full = SetOfMarks.jpeg(frame, quality: 0.8) else { throw LookError.encoding }
            let seg = try await client.segment(SegmentRequest(jpeg: full, prompts: Array(prompts.prefix(4))))
            let marked = SetOfMarks.render(frame, instances: seg.instances).flatMap { SetOfMarks.jpeg($0, quality: 0.8) } ?? full
            emit(.segmented(seg, markedJPEG: marked))
            for inst in seg.instances {
                marks[inst.id] = MarkInfo(id: inst.id, confidence: inst.confidence)
                resolved.insert(inst.id)
            }
            system = PipPrompt.systemMarks(language: language)
            message = PipPrompt.lookMessage(goal: request.goal, step: request.step, facts: request.facts, marks: seg.instances, utterance: request.utterance, frameJPEG: context, markedJPEG: marked)
        } else {
            system = PipPrompt.system(language: language)
            message = PipPrompt.lookMessage(goal: request.goal, step: request.step, facts: request.facts, utterance: request.utterance, frameJPEG: context)
        }

        var chat = ChatRequest(messages: [.system(system)] + request.history + [message], stream: true, reasoningEffort: effort,
                               promptCacheKey: promptCacheKey, maxCompletionTokens: 4000)
        chat.model = model
        // The frame is at most 1280 px already, so Spark and SAM can share one encoding.
        let grounder = Grounder(client: client, frameJPEG: context)
        let (inputs, feed) = AsyncStream<Input>.makeStream()
        let chatTask = Task {
            do {
                for try await e in client.chatStream(chat) { feed.yield(.chat(e)) }
                feed.yield(.chatEnded(nil))
            } catch {
                feed.yield(.chatEnded(String(describing: error)))
            }
        }
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                feed.yield(.tick)
            }
        }
        var groundTasks: [Task<Void, Never>] = []
        defer {
            chatTask.cancel()
            ticker.cancel()
            groundTasks.forEach { $0.cancel() }
            feed.finish()
        }

        var parser = CueStreamParser()
        var raw = ""
        var usage: ChatUsage?
        var firstToken: Double?
        var firstSentence: Double?
        var pending: [(sentence: SpokenSentence, completed: Date)] = []
        var chatDone = false

        func handle(_ events: [CueStreamEvent]) {
            for e in events {
                switch e {
                case .target(let id, let spec):
                    emit(.target(id: id, spec: spec))
                    groundTasks.append(Task {
                        let r = await grounder.ground(spec, id: id, frame: frame)
                        feed.yield(.grounded(id, r))
                    })
                case .sentence(let s):
                    pending.append((s, Date()))
                case .sideChannel(let cue, _):
                    emit(.sideChannel(cue))
                case .invalidTag(let err):
                    emit(.invalidTag(err))
                }
            }
        }

        /// Releases sentences in order once their targets are grounded (or the wait is over).
        func flush() {
            while let first = pending.first {
                let needed = Set(first.sentence.cues.flatMap { $0.cue.marks })
                guard needed.isSubset(of: resolved) || since(first.completed) > groundingTimeout else { return }
                var s = first.sentence
                var traces: [CueTrace] = []
                var kept: [TimedCue] = []
                for timed in s.cues {
                    let decision = validator.validate(timed.cue, marks: marks, hasEvidence: { _ in false })
                    traces.append(CueTrace(raw: timed.raw, decision: decision))
                    if let cue = decision.cue { kept.append(TimedCue(cue: cue, anchor: timed.anchor, raw: timed.raw)) }
                }
                s.cues = kept
                firstSentence = firstSentence ?? since(t0)
                emit(.sentence(s, traces: traces))
                pending.removeFirst()
            }
        }

        for await input in inputs {
            if Task.isCancelled { break }
            switch input {
            case .chat(.delta(let text)):
                firstToken = firstToken ?? since(t0)
                raw += text
                handle(parser.feed(text))
            case .chat(.usage(let u)):
                usage = u
            case .chat(.finished):
                break
            case .chatEnded(let error):
                if let error { throw LookError.chat(error) }
                handle(parser.finish())
                chatDone = true
            case .grounded(let id, let result):
                resolved.insert(id)
                if let inst = result.instance { marks[id] = MarkInfo(id: id, confidence: inst.confidence) }
                emit(.grounded(id: id, instance: result.instance, method: result.method, seconds: result.seconds))
            case .tick:
                break
            }
            flush()
            if chatDone && pending.isEmpty { break }
        }

        emit(.finished(LookSummary(rawText: raw, usage: usage, firstTokenSeconds: firstToken, firstSentenceSeconds: firstSentence, totalSeconds: since(t0))))
    }
}

public enum LookError: Error {
    case encoding
    case chat(String)
}
