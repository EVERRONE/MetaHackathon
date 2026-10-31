import AVFAudio
import Foundation
import PipCore
import UIKit

/// Hands-free conversation: live transcription → look → speech with synced cues.
/// Talking over Pip stops it at once (barge-in); the mute button sends silence instead.
@MainActor
final class GuideModel: ObservableObject {
    enum Phase: Equatable {
        case connecting, listening, hearing, looking, speaking, muted
        case failed(String)

        var label: String {
            switch self {
            case .connecting: return "Connecting…"
            case .listening: return "Listening"
            case .hearing: return "Hearing you…"
            case .looking: return "Looking…"
            case .speaking: return "Speaking"
            case .muted: return "Muted"
            case .failed(let m): return m
            }
        }
    }

    @Published var phase: Phase = .connecting
    @Published var caption = ""
    @Published var heard = ""
    @Published var markedImage: UIImage?
    @Published var trace: [String] = []
    @Published var muted = false
    @Published var language = "English" {
        didSet {
            configureVoice()
            restartListening()
        }
    }

    /// ElevenLabs voices: Sharon (Flemish, multilingual) and Alice (British English).
    static let cloudVoices = ["Dutch": "g7B5PNoscIXomLNUmHAb", "English": "Xb7hH8MSUJpSbSDYk0k2"]

    let ar = ARController()
    private let audio = AudioIO()
    private let speaker: Speaker
    private let client: PipClient
    private var transcriber: RealtimeTranscriber?
    private var listenTask: Task<Void, Never>?
    private var history: [ChatMessage] = []
    private var task: Task<Void, Never>?
    private var spokenThisTurn: [String] = []
    private var lookActive = false

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let base = URL(string: info["PIPBaseURL"] as? String ?? "") ?? URL(string: "https://pip.unveil.be")!
        client = PipClient(baseURL: base, token: info["PIPAppToken"] as? String ?? "")
        speaker = Speaker(engine: audio.engine, player: audio.player)
        configureVoice()
        speaker.onLog = { [weak self] line in self?.log(line) }
        speaker.onSentenceStart = { [weak self] s in
            self?.caption = s.text
            self?.spokenThisTurn.append(s.text)
        }
        speaker.onCue = { [weak self] c in self?.ar.show(c.cue) }
        speaker.onIdle = { [weak self] in
            guard let self, self.phase == .speaking, !self.lookActive else { return }
            self.phase = self.muted ? .muted : .listening
        }
    }

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? session.setActive(true)
        ar.start()
        Task.detached(priority: .utility) { await Grounder.warmUp() }
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                guard granted else { self.phase = .failed("Microphone access is off"); return }
                self.audio.onPCM = { [weak self] pcm in self?.transcriber?.send(pcm: pcm) }
                do { try self.audio.start() } catch { self.phase = .failed("Audio unavailable: \(error)") }
                self.restartListening()
            }
        }
    }

    private func configureVoice() {
        speaker.voice = Speaker.bestVoice(for: language)
        speaker.cloud = Self.cloudVoices[language].map {
            Speaker.CloudVoice(client: client, voiceId: $0, language: language == "Dutch" ? "nl" : "en")
        }
    }

    /// The big button: stop Pip if it is talking, otherwise mute or unmute the microphone.
    func micTapped() {
        if speaker.isSpeaking || lookActive {
            interrupt()
            return
        }
        muted.toggle()
        audio.muted = muted
        phase = muted ? .muted : .listening
    }

    private func interrupt() {
        speaker.stop()
        task?.cancel()
        lookActive = false
        phase = muted ? .muted : .listening
    }

    private func restartListening() {
        listenTask?.cancel()
        transcriber?.close()
        let asr = RealtimeTranscriber(baseURL: client.baseURL, token: client.token,
                                      languages: language == "Dutch" ? ["Dutch", "English"] : ["English", "Dutch"])
        transcriber = asr
        phase = .connecting
        asr.connect()
        listenTask = Task { [weak self] in
            for await event in asr.events {
                guard let self, !Task.isCancelled else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: RealtimeTranscriber.Event) {
        switch event {
        case .ready:
            log("listening")
            if phase == .connecting { phase = muted ? .muted : .listening }
        case .speechStart:
            guard !muted else { return }
            // Barge-in: the user talks over Pip.
            if speaker.isSpeaking || lookActive {
                log("barge-in")
                interrupt()
            }
            heard = ""
            phase = .hearing
        case .partial(let text):
            guard !muted, !isEcho(text) else { return }
            heard = text
        case .speechEnd:
            break
        case .final(_, let text):
            guard !muted, text.count >= 2, !isEcho(text) else {
                if phase == .hearing { phase = .listening }
                return
            }
            heard = text
            // The frame the user was looking at when they finished speaking.
            guard let snapshot = ar.snapshot() else { return }
            let t0 = Date()
            task?.cancel()
            task = Task { await self.look(text, snapshot: snapshot, started: t0) }
        case .error(let message):
            log("asr error: \(message)")
        case .closed(let code, let reason):
            log("asr closed \(code) \(reason)")
            // Sessions end after a while; reconnect quietly.
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.restartListening()
            }
        }
    }

    /// Pip's own voice picked up despite echo cancellation: the words are mostly what Pip just said.
    private func isEcho(_ text: String) -> Bool {
        let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        guard words.count >= 2 else { return false }
        let spoken = Set(speaker.recentText.joined(separator: " ").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let overlap = Double(words.intersection(spoken).count) / Double(words.count)
        return overlap > 0.8
    }

    private func look(_ utterance: String, snapshot: FrameSnapshot, started: Date) async {
        lookActive = true
        defer { lookActive = false }
        phase = .looking
        spokenThisTurn = []
        ar.beginLook()
        let recorder = LookRecorder(utterance: utterance, language: language, frame: snapshot.image)
        func note(_ line: String) {
            log(line)
            recorder?.log(line)
        }
        let pipeline = LookPipeline(client: client, language: language)
        let request = LookRequest(frame: snapshot.image, history: history, utterance: utterance)
        var firstWord: Double?
        var raw: String?
        do {
            for try await event in pipeline.run(request) {
                if Task.isCancelled { break }
                switch event {
                case .target(let id, let spec):
                    note("target \(id): \(spec.phrase) \(spec.text) @\(Int(spec.x)),\(Int(spec.y))")
                case .grounded(let id, let inst, let method, let seconds):
                    if let inst {
                        let anchoring = ar.addMark(inst, snapshot: snapshot)
                        recorder?.grounded(inst)
                        note(String(format: "grounded %d via %@ in %.1fs, anchored on %@", id, method, seconds, anchoring))
                    } else {
                        note(String(format: "target %d not grounded (%@)", id, method))
                    }
                case .segmented(let s, let marked):
                    for inst in s.instances { ar.addMark(inst, snapshot: snapshot) }
                    markedImage = UIImage(data: marked)
                case .sentence(let s, let traces):
                    firstWord = firstWord ?? Date().timeIntervalSince(started)
                    phase = .speaking
                    speaker.enqueue(s)
                    note("say: \(s.text)")
                    for t in traces { note("  cue \(t.raw): \(t.decision)") }
                case .sideChannel(let cue):
                    note("side: \(cue)")
                case .invalidTag(let e):
                    note("invalid: \(e)")
                case .finished(let summary):
                    raw = summary.rawText
                    note(String(format: "first word %.1fs after you stopped · total %.1fs", firstWord ?? -1, Date().timeIntervalSince(started)))
                    if let u = summary.usage { note("tokens \(u.promptTokens) in (\(u.promptTokensDetails?.cachedTokens ?? 0) cached), \(u.completionTokens) out") }
                }
            }
            remember(utterance)
            if !speaker.isSpeaking, phase == .looking { phase = muted ? .muted : .listening }
        } catch {
            note("error: \(error)")
            if !Task.isCancelled { phase = .failed("Look failed: \(error)") }
        }
        recorder?.finish(rawText: raw)
    }

    /// Keeps the last few turns as they were heard, for follow-up questions.
    private func remember(_ utterance: String) {
        history.append(.user(utterance))
        history.append(.assistant(spokenThisTurn.joined(separator: " ")))
        if history.count > 8 { history.removeFirst(history.count - 8) }
    }

    func resetConversation() {
        interrupt()
        history = []
        caption = ""
        heard = ""
        ar.clearCues()
    }

    private func log(_ line: String) {
        trace.append(line)
        if trace.count > 60 { trace.removeFirst(trace.count - 60) }
    }
}
