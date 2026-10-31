import AVFAudio
import Foundation
import PipCore
import QuartzCore

/// Speaks sentences and fires each cue just before the word it belongs to.
///
/// Voices: ElevenLabs through the Worker (with each character's start time), or the iPhone's own
/// voice as a fallback (with word markers; `byteSampleOffset` is a byte offset into the synthesised
/// audio, measured: 4 bytes per Float32 frame). Each sentence is rendered as soon as it is queued,
/// so the next one is ready when the current one ends.
final class Speaker {
    /// Research: show a cue 300–800 ms before the noun it goes with.
    static let cueLead: TimeInterval = 0.4

    struct CloudVoice {
        var client: PipClient
        var voiceId: String
        var language: String
    }

    var cloud: CloudVoice?
    var voice: AVSpeechSynthesisVoice?
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var onSentenceStart: ((SpokenSentence) -> Void)?
    var onCue: ((TimedCue) -> Void)?
    var onIdle: (() -> Void)?
    var onLog: ((String) -> Void)?

    /// The text of what is being said now, for telling the user's speech from Pip's own echo.
    private(set) var recentText: [String] = []

    private struct Rendered {
        var buffers: [AVAudioPCMBuffer]
        /// Start time (s) of the text at a UTF-16 offset.
        var time: (Int) -> Double
        var source: String
    }

    private struct Item {
        var sentence: SpokenSentence
        var audio: Task<Rendered?, Never>
    }

    private let synth = AVSpeechSynthesizer()
    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    private var playerFormat: AVAudioFormat?
    private var queue: [Item] = []
    private var busy = false
    private var generation = 0
    private var pendingCues: [DispatchWorkItem] = []

    /// Plays through the shared engine, so voice processing can cancel Pip's own voice.
    init(engine: AVAudioEngine, player: AVAudioPlayerNode) {
        self.engine = engine
        self.player = player
    }

    var isSpeaking: Bool { busy || !queue.isEmpty }

    func enqueue(_ sentence: SpokenSentence) {
        let text = sentence.text
        let audio = Task { await self.render(text) }
        queue.append(Item(sentence: sentence, audio: audio))
        pump()
    }

    /// Stops at once (barge-in): audio, queued sentences and cues that have not fired yet.
    func stop() {
        generation += 1
        queue.forEach { $0.audio.cancel() }
        queue.removeAll()
        pendingCues.forEach { $0.cancel() }
        pendingCues.removeAll()
        player.stop()
        busy = false
    }

    private func pump() {
        guard !busy else { return }
        guard !queue.isEmpty else { onIdle?(); return }
        busy = true
        let item = queue.removeFirst()
        let gen = generation
        Task { @MainActor [weak self] in
            let rendered = await item.audio.value
            guard let self, gen == self.generation else { return }
            guard let rendered, !rendered.buffers.isEmpty else {
                self.busy = false
                self.pump()
                return
            }
            self.play(item.sentence, rendered, generation: gen)
        }
    }

    // MARK: Rendering

    private func render(_ text: String) async -> Rendered? {
        if let cloud {
            do {
                let audio = try await cloud.client.speak(text: text, voice: cloud.voiceId, language: cloud.language)
                if let buffer = Self.buffer(fromPCM16: audio.pcm, rate: SpokenAudio.sampleRate) {
                    return Rendered(buffers: [buffer], time: { audio.startTime(atUTF16: $0, in: text) ?? 0 }, source: "elevenlabs")
                }
            } catch {
                if !Task.isCancelled { await MainActor.run { self.onLog?("voice fallback: \(error)") } }
            }
        }
        return await renderOnDevice(text)
    }

    private final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var buffers: [AVAudioPCMBuffer] = []
        var markers: [AVSpeechSynthesisMarker] = []
        var done = false
    }

    private func renderOnDevice(_ text: String) async -> Rendered? {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = rate
        let c = Collector()
        let (buffers, markers): ([AVAudioPCMBuffer], [AVSpeechSynthesisMarker]) = await withCheckedContinuation { cont in
            synth.write(u, toBufferCallback: { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                c.lock.lock()
                defer { c.lock.unlock() }
                guard !c.done else { return }
                if pcm.frameLength == 0 {
                    c.done = true
                    cont.resume(returning: (c.buffers, c.markers))
                } else {
                    c.buffers.append(pcm)
                }
            }, toMarkerCallback: { m in
                c.lock.lock()
                c.markers += m
                c.lock.unlock()
            })
        }
        guard let format = buffers.first?.format else { return nil }
        let bytesPerFrame = Double(format.streamDescription.pointee.mBytesPerFrame)
        let words = markers.filter { $0.mark == .word }.map { (location: $0.textRange.location, time: Double($0.byteSampleOffset) / bytesPerFrame / format.sampleRate) }
        return Rendered(buffers: buffers, time: { anchor in
            words.first(where: { $0.location >= anchor })?.time ?? words.last?.time ?? 0
        }, source: "on-device")
    }

    /// 16-bit PCM → a Float32 buffer the mixer accepts.
    private static func buffer(fromPCM16 data: Data, rate: Double) -> AVAudioPCMBuffer? {
        let frames = data.count / 2
        guard frames > 0, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), let out = buf.floatChannelData?[0] else { return nil }
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: src[i])) / 32768 }
        }
        buf.frameLength = AVAudioFrameCount(frames)
        return buf
    }

    // MARK: Playback

    private func play(_ sentence: SpokenSentence, _ rendered: Rendered, generation gen: Int) {
        guard let format = rendered.buffers.first?.format else { return }
        connect(format)
        for (i, b) in rendered.buffers.enumerated() {
            let last = i == rendered.buffers.count - 1
            player.scheduleBuffer(b, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard last else { return }
                DispatchQueue.main.async {
                    guard let self, gen == self.generation else { return }
                    self.busy = false
                    self.pump()
                }
            }
        }
        if !engine.isRunning { try? engine.start() }
        player.play()
        let latency = AVAudioSession.sharedInstance().outputLatency
        recentText.append(sentence.text)
        if recentText.count > 6 { recentText.removeFirst() }
        onSentenceStart?(sentence)

        for cue in sentence.cues {
            let delay = max(0, rendered.time(cue.anchor) - Self.cueLead + latency)
            let item = DispatchWorkItem { [weak self] in
                guard let self, gen == self.generation else { return }
                self.onCue?(cue)
            }
            pendingCues.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func connect(_ format: AVAudioFormat) {
        guard playerFormat != format else { return }
        player.stop()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        playerFormat = format
    }

    /// The best installed on-device voice for a language: premium, then enhanced, then default.
    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let prefixes: [String]
        switch language.lowercased() {
        case "dutch": prefixes = ["nl-BE", "nl-NL", "nl"]
        default: prefixes = ["en-GB", "en-US", "en"]
        }
        let voices = AVSpeechSynthesisVoice.speechVoices()
        for prefix in prefixes {
            let matching = voices.filter { $0.language.hasPrefix(prefix) }
            if let best = matching.max(by: { $0.quality.rawValue < $1.quality.rawValue }) { return best }
        }
        return AVSpeechSynthesisVoice(language: prefixes.first)
    }
}
