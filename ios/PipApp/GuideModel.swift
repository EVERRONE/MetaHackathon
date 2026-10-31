import AVFAudio
import Foundation
import PipCore
import UIKit

/// Push-to-talk → transcribe → look → speak with synced cues.
@MainActor
final class GuideModel: ObservableObject {
    enum Phase: Equatable {
        case idle, listening, transcribing, looking, speaking
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Tap to ask"
            case .listening: return "Listening… tap when done"
            case .transcribing: return "Hearing you…"
            case .looking: return "Looking…"
            case .speaking: return "Speaking"
            case .failed(let m): return m
            }
        }
    }

    @Published var phase: Phase = .idle
    @Published var caption = ""
    @Published var heard = ""
    @Published var markedImage: UIImage?
    @Published var trace: [String] = []
    @Published var language = "English" {
        didSet { speaker.voice = Speaker.bestVoice(for: language) }
    }

    let ar = ARController()
    private let speaker = Speaker()
    private let recorder = Recorder()
    private let client: PipClient
    private var history: [ChatMessage] = []
    private var task: Task<Void, Never>?
    private var spokenThisTurn: [String] = []

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let base = URL(string: info["PIPBaseURL"] as? String ?? "") ?? URL(string: "https://pip.unveil.be")!
        client = PipClient(baseURL: base, token: info["PIPAppToken"] as? String ?? "")
        speaker.voice = Speaker.bestVoice(for: language)
        speaker.onSentenceStart = { [weak self] s in
            self?.caption = s.text
            self?.spokenThisTurn.append(s.text)
        }
        speaker.onCue = { [weak self] c in self?.ar.show(c.cue) }
        speaker.onIdle = { [weak self] in
            guard let self, self.phase == .speaking else { return }
            self.phase = .idle
        }
    }

    func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setActive(true)
        AVAudioApplication.requestRecordPermission { _ in }
        ar.start()
    }

    func micTapped() {
        switch phase {
        case .listening:
            finishListening()
        case .transcribing, .looking:
            task?.cancel()
            speaker.stop()
            phase = .idle
        default:
            startListening()
        }
    }

    private func startListening() {
        // Barge-in: stop talking the moment the user wants to speak.
        speaker.stop()
        task?.cancel()
        do {
            try recorder.start()
            phase = .listening
            heard = ""
        } catch {
            phase = .failed("Microphone unavailable")
        }
    }

    private func finishListening() {
        let (wav, seconds) = recorder.stop()
        // The frame the user was looking at when they finished speaking.
        guard let snapshot = ar.snapshot() else { phase = .failed("No camera frame yet"); return }
        guard seconds > 0.3 else { phase = .idle; return }
        phase = .transcribing
        let t0 = Date()
        task = Task {
            do {
                let transcript = try await client.transcribe(wav: wav, languages: language == "Dutch" ? ["Dutch", "English"] : ["English", "Dutch"])
                let text = transcript.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                log(String(format: "ASR %.1fs: %@", Date().timeIntervalSince(t0), text))
                guard !text.isEmpty, !Task.isCancelled else { phase = .idle; return }
                heard = text
                await look(text, snapshot: snapshot, started: t0)
            } catch {
                phase = .failed("Could not hear that: \(error)")
            }
        }
    }

    private func look(_ utterance: String, snapshot: FrameSnapshot, started: Date) async {
        phase = .looking
        spokenThisTurn = []
        let pipeline = LookPipeline(client: client, language: language)
        let request = LookRequest(frame: snapshot.image, history: history, utterance: utterance)
        var firstWord: Double?
        do {
            for try await event in pipeline.run(request) {
                if Task.isCancelled { return }
                switch event {
                case .phrases(let p):
                    log("SAM prompts: \(p.joined(separator: ", "))")
                case .segmented(let s, let marked):
                    ar.setMarks(s.instances, snapshot: snapshot)
                    markedImage = UIImage(data: marked)
                    log("SAM: \(s.instances.count) marks, \(ar.anchoredCount) anchored in 3D")
                case .sentence(let s, let traces):
                    firstWord = firstWord ?? Date().timeIntervalSince(started)
                    phase = .speaking
                    speaker.enqueue(s)
                    for t in traces { log("cue \(t.raw): \(t.decision)") }
                case .sideChannel(let cue):
                    log("side: \(cue)")
                case .invalidTag(let e):
                    log("invalid: \(e)")
                case .finished(let summary):
                    log(String(format: "first word %.1fs after you stopped · total %.1fs", firstWord ?? -1, Date().timeIntervalSince(started)))
                    if let u = summary.usage { log("tokens \(u.promptTokens) in (\(u.promptTokensDetails?.cachedTokens ?? 0) cached), \(u.completionTokens) out") }
                }
            }
            remember(utterance)
            if !speaker.isSpeaking, phase == .looking { phase = .idle }
        } catch {
            if !Task.isCancelled { phase = .failed("Look failed: \(error)") }
        }
    }

    /// Keeps the last few turns as they were heard, for follow-up questions.
    private func remember(_ utterance: String) {
        history.append(.user(utterance))
        history.append(.assistant(spokenThisTurn.joined(separator: " ")))
        if history.count > 8 { history.removeFirst(history.count - 8) }
    }

    func resetConversation() {
        speaker.stop()
        task?.cancel()
        history = []
        caption = ""
        heard = ""
        ar.clearCues()
        phase = .idle
    }

    private func log(_ line: String) {
        trace.append(line)
        if trace.count > 60 { trace.removeFirst(trace.count - 60) }
    }
}
