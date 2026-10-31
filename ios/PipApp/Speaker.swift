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

    /// What was said recently and when, for telling the user's speech from Pip's own echo.
    private(set) var recentText: [String] = []
    private(set) var lastSpokeAt = Date.distantPast

    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    private let device = DeviceVoice()
    private var playerFormat: AVAudioFormat?
    private var queue: [Item] = []
    private var busy = false
    private var generation = 0
    private var pendingCues: [DispatchWorkItem] = []

    private struct Item {
        var sentence: SpokenSentence
        var audio: Task<RenderedSpeech?, Never>
    }

    /// Plays through the shared engine, so voice processing can cancel Pip's own voice.
    init(engine: AVAudioEngine, player: AVAudioPlayerNode) {
        self.engine = engine
        self.player = player
    }

    var isSpeaking: Bool { busy || !queue.isEmpty }

    func enqueue(_ sentence: SpokenSentence) {
        // Settings are read here, on the main thread, not inside the background render.
        let text = sentence.text, cloud = cloud, voice = voice, rate = rate, device = device
        let log = onLog
        let audio = Task { () -> RenderedSpeech? in
            if let cloud {
                do {
                    let spoken = try await cloud.client.speak(text: text, voice: cloud.voiceId, language: cloud.language)
                    if let buffer = Self.buffer(fromPCM16: spoken.pcm, rate: SpokenAudio.sampleRate) {
                        return RenderedSpeech(buffers: [buffer], time: { spoken.startTime(atUTF16: $0, in: text) ?? 0 })
                    }
                } catch {
                    // Stopped by barge-in: no fallback for speech nobody will hear.
                    if Task.isCancelled { return nil }
                    await MainActor.run { log?("voice fallback: \(error)") }
                }
            }
            if Task.isCancelled { return nil }
            return await device.render(text, voice: voice, rate: rate)
        }
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
        if busy { lastSpokeAt = Date() }
        busy = false
    }

    private func pump() {
        guard !busy else { return }
        guard !queue.isEmpty else {
            // Every cue of the finished sentences has fired by now.
            pendingCues.removeAll()
            onIdle?()
            return
        }
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

    /// 16-bit PCM → a Float32 buffer the mixer accepts.
    static func buffer(fromPCM16 data: Data, rate: Double) -> AVAudioPCMBuffer? {
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

    private func play(_ sentence: SpokenSentence, _ rendered: RenderedSpeech, generation gen: Int) {
        guard let format = rendered.buffers.first?.format else { return }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else {
            // No audio right now (an interruption): skip the sentence rather than crash.
            onLog?("audio engine not running; sentence skipped")
            busy = false
            pump()
            return
        }
        connect(format)
        for (i, b) in rendered.buffers.enumerated() {
            let last = i == rendered.buffers.count - 1
            player.scheduleBuffer(b, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard last else { return }
                DispatchQueue.main.async {
                    guard let self, gen == self.generation else { return }
                    self.lastSpokeAt = Date()
                    self.busy = false
                    self.pump()
                }
            }
        }
        player.play()
        let latency = AVAudioSession.sharedInstance().outputLatency
        recentText.append(sentence.text)
        if recentText.count > 6 { recentText.removeFirst() }
        lastSpokeAt = Date()
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

/// Audio for one sentence and the start time of the text at a UTF-16 offset.
struct RenderedSpeech: @unchecked Sendable {
    var buffers: [AVAudioPCMBuffer]
    var time: (Int) -> Double
}

/// The iPhone's own voice. Renders one sentence at a time (one synthesiser), and gives up after
/// a while if the synthesiser never signals the end, so the speech queue cannot stall.
actor DeviceVoice {
    private let synth = AVSpeechSynthesizer()
    private var tail: Task<Void, Never>?

    func render(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Float) async -> RenderedSpeech? {
        let previous = tail
        let task = Task { () -> RenderedSpeech? in
            await previous?.value
            return await self.renderNow(text, voice: voice, rate: rate)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var buffers: [AVAudioPCMBuffer] = []
        var markers: [AVSpeechSynthesisMarker] = []
        var continuation: CheckedContinuation<([AVAudioPCMBuffer], [AVSpeechSynthesisMarker])?, Never>?

        func finish(_ ok: Bool) {
            lock.lock()
            let c = continuation
            continuation = nil
            let result = ok ? (buffers, markers) : nil
            lock.unlock()
            c?.resume(returning: result)
        }
    }

    private func renderNow(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Float) async -> RenderedSpeech? {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = rate
        let c = Collector()
        let result: ([AVAudioPCMBuffer], [AVSpeechSynthesisMarker])? = await withCheckedContinuation { cont in
            c.continuation = cont
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { c.finish(false) }
            synth.write(u, toBufferCallback: { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    c.finish(true)
                } else {
                    c.lock.lock(); c.buffers.append(pcm); c.lock.unlock()
                }
            }, toMarkerCallback: { m in
                c.lock.lock(); c.markers += m; c.lock.unlock()
            })
        }
        guard let (buffers, markers) = result, let format = buffers.first?.format else { return nil }
        let bytesPerFrame = Double(format.streamDescription.pointee.mBytesPerFrame)
        let words = markers.filter { $0.mark == .word }.map { (location: $0.textRange.location, time: Double($0.byteSampleOffset) / bytesPerFrame / format.sampleRate) }
        return RenderedSpeech(buffers: buffers, time: { anchor in
            words.first(where: { $0.location >= anchor })?.time ?? words.last?.time ?? 0
        })
    }
}
