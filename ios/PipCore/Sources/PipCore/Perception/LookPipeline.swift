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
    public var phrasesSeconds: Double?
    public var segmentSeconds: Double
    public var firstTokenSeconds: Double?
    public var firstSentenceSeconds: Double?
    public var totalSeconds: Double
}

public enum LookEvent: Sendable {
    case phrases([String])
    case segmented(SegmentResponse, markedJPEG: Data)
    /// A sentence with only the cues that passed validation.
    case sentence(SpokenSentence, traces: [CueTrace])
    case sideChannel(Cue)
    case invalidTag(CueError)
    case finished(LookSummary)
}

public struct LookRequest: Sendable {
    public var frame: CGImage
    /// SAM noun phrases. When nil, Spark picks them from the utterance first.
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

/// One "look": segment → numbered marks → Spark streams speech with cue tags → validated sentences.
public struct LookPipeline: Sendable {
    public var client: PipClient
    public var validator: CueValidator
    public var language: String
    public var promptCacheKey: String

    public init(client: PipClient, validator: CueValidator = CueValidator(), language: String = "English") {
        self.client = client
        self.validator = validator
        self.language = language
        self.promptCacheKey = "pip-\(PipPrompt.version)-\(language.lowercased())"
    }

    public func run(_ request: LookRequest, hasEvidence: @escaping @Sendable (Int) -> Bool = { _ in false }) -> AsyncThrowingStream<LookEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await perform(request, hasEvidence: hasEvidence) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func perform(_ request: LookRequest, hasEvidence: @escaping @Sendable (Int) -> Bool, emit: (LookEvent) -> Void) async throws {
        let t0 = Date()
        func since(_ t: Date) -> Double { Date().timeIntervalSince(t) }
        guard let clean = SetOfMarks.jpeg(request.frame, quality: 0.8) else { throw LookError.encoding }

        var phrasesSeconds: Double?
        var prompts = request.prompts ?? []
        if request.prompts == nil {
            let tp = Date()
            prompts = try await nounPhrases(utterance: request.utterance, goal: request.goal, jpeg: clean)
            phrasesSeconds = since(tp)
            emit(.phrases(prompts))
        }

        let ts = Date()
        let segment = prompts.isEmpty
            ? SegmentResponse(width: request.frame.width, height: request.frame.height, instances: [], calls: [], dropped: 0)
            : try await client.segment(SegmentRequest(jpeg: clean, prompts: Array(prompts.prefix(4))))
        let segmentSeconds = since(ts)
        let marked = SetOfMarks.render(request.frame, instances: segment.instances).flatMap { SetOfMarks.jpeg($0, quality: 0.8) } ?? clean
        emit(.segmented(segment, markedJPEG: marked))

        let marks = Dictionary(uniqueKeysWithValues: segment.instances.map { ($0.id, MarkInfo(id: $0.id, confidence: $0.confidence)) })
        let messages = [ChatMessage.system(PipPrompt.system(language: language))] + request.history + [
            PipPrompt.lookMessage(goal: request.goal, step: request.step, facts: request.facts, marks: segment.instances, utterance: request.utterance, cleanJPEG: clean, markedJPEG: marked),
        ]
        let chat = ChatRequest(messages: messages, stream: true, reasoningEffort: .minimal, promptCacheKey: promptCacheKey, maxCompletionTokens: 2000)

        var parser = CueStreamParser()
        var raw = ""
        var usage: ChatUsage?
        let tc = Date()
        var firstToken: Double?
        var firstSentence: Double?

        func handle(_ events: [CueStreamEvent]) {
            for e in events {
                switch e {
                case .sentence(var s):
                    var traces: [CueTrace] = []
                    var kept: [TimedCue] = []
                    for timed in s.cues {
                        let decision = validator.validate(timed.cue, marks: marks, hasEvidence: hasEvidence)
                        traces.append(CueTrace(raw: timed.raw, decision: decision))
                        if let cue = decision.cue { kept.append(TimedCue(cue: cue, anchor: timed.anchor, raw: timed.raw)) }
                    }
                    s.cues = kept
                    firstSentence = firstSentence ?? since(tc)
                    emit(.sentence(s, traces: traces))
                case .sideChannel(let cue, _):
                    emit(.sideChannel(cue))
                case .invalidTag(let err):
                    emit(.invalidTag(err))
                }
            }
        }

        for try await event in client.chatStream(chat) {
            switch event {
            case .delta(let text):
                firstToken = firstToken ?? since(tc)
                raw += text
                handle(parser.feed(text))
            case .usage(let u):
                usage = u
            case .finished:
                break
            }
        }
        handle(parser.finish())

        emit(.finished(LookSummary(rawText: raw, usage: usage, phrasesSeconds: phrasesSeconds, segmentSeconds: segmentSeconds,
                                   firstTokenSeconds: firstToken.map { $0 + segmentSeconds + (phrasesSeconds ?? 0) },
                                   firstSentenceSeconds: firstSentence.map { $0 + segmentSeconds + (phrasesSeconds ?? 0) },
                                   totalSeconds: since(t0))))
    }

    func nounPhrases(utterance: String, goal: String?, jpeg: Data) async throws -> [String] {
        struct Out: Decodable { var phrases: [String] }
        let (text, _) = try await client.chat(PipPrompt.nounPhraseRequest(utterance: utterance, goal: goal, cleanJPEG: jpeg))
        let out = try JSONDecoder().decode(Out.self, from: Data(text.utf8))
        return out.phrases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }.prefix(3).map { $0 }
    }
}

public enum LookError: Error {
    case encoding
}
