import AVFAudio
import Foundation
import PipCore
import QuartzCore

/// Speaks sentences and fires each cue just before the word it belongs to.
///
/// Voices: ElevenLabs through the Worker (with each character's start time), streamed: a
/// sentence starts playing with its first piece of audio, and each cue is timed as soon as its
/// word's time arrives. The iPhone's own voice is the fallback (with word markers;
/// `byteSampleOffset` is a byte offset into the synthesised audio, measured: 4 bytes per Float32
/// frame). Each sentence's speech is requested as soon as it is queued, so the next one is ready
/// when the current one ends.
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
    /// The streamed sentence playing now (to cancel on stop).
    private var current: StreamedSpeech?

    private struct Item {
        var sentence: SpokenSentence
        var speech: Speech
        var enqueued: CFTimeInterval
        /// The first sentence after silence: its delay is what the user waits for.
        var first: Bool

        func cancel() {
            switch speech {
            case .streamed(let s): s.cancel()
            case .rendered(let t): t.cancel()
            }
        }
    }

    private enum Speech {
        case streamed(StreamedSpeech)
        case rendered(Task<RenderedSpeech?, Never>)
    }

    /// Plays through the shared engine, so voice processing can cancel Pip's own voice.
    init(engine: AVAudioEngine, player: AVAudioPlayerNode) {
        self.engine = engine
        self.player = player
    }

    var isSpeaking: Bool { busy || !queue.isEmpty }

    func enqueue(_ sentence: SpokenSentence) {
        // Settings are read here, on the main thread, not inside the background work.
        let text = sentence.text, voice = voice, rate = rate, device = device
        let speech: Speech
        if let cloud {
            let s = StreamedSpeech()
            let log = onLog
            s.task = Task { @MainActor [weak s] in
                // An odd byte at the end of a piece belongs to the next one.
                var carry = Data()
                do {
                    for try await chunk in cloud.client.speakStream(text: text, voice: cloud.voiceId, language: cloud.language) {
                        guard let s else { return }
                        var pcm = carry + chunk.pcm
                        if pcm.count % 2 == 1 {
                            carry = pcm.suffix(1)
                            pcm.removeLast()
                        } else {
                            carry = Data()
                        }
                        if let b = Self.buffer(fromPCM16: pcm, rate: SpeechTiming.sampleRate) { s.buffers.append(b) }
                        s.timing.characters += chunk.characters
                        s.timing.starts += chunk.starts
                        s.changed()
                    }
                } catch {
                    // Stopped by barge-in: nobody waits for this speech.
                    if !Task.isCancelled { log?("voice: \(error)") }
                }
                s?.finished = true
                s?.changed()
            }
            speech = .streamed(s)
        } else {
            speech = .rendered(Task { await device.render(text, voice: voice, rate: rate) })
        }
        queue.append(Item(sentence: sentence, speech: speech, enqueued: CACurrentMediaTime(), first: !busy && queue.isEmpty))
        pump()
    }

    /// Stops at once (barge-in): audio, queued sentences and cues that have not fired yet.
    func stop() {
        generation += 1
        queue.forEach { $0.cancel() }
        queue.removeAll()
        current?.cancel()
        current = nil
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
        switch item.speech {
        case .rendered(let task):
            Task { @MainActor [weak self] in
                let rendered = await task.value
                guard let self, gen == self.generation else { return }
                self.play(item, rendered, generation: gen)
            }
        case .streamed(let s):
            current = s
            var begun = false
            // As soon as the first audio is there; with none at all, the iPhone's own voice.
            func begin() {
                guard gen == generation, !begun else { return }
                if !s.buffers.isEmpty {
                    begun = true
                    playStreamed(item, s, generation: gen)
                } else if s.finished {
                    begun = true
                    s.onChange = nil
                    if current === s { current = nil }
                    let text = item.sentence.text, voice = voice, rate = rate, device = device
                    Task { @MainActor [weak self] in
                        let rendered = await device.render(text, voice: voice, rate: rate)
                        guard let self, gen == self.generation else { return }
                        self.play(item, rendered, generation: gen)
                    }
                }
            }
            s.onChange = { begin() }
            begin()
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

    /// Whether the engine runs (an interruption can stop it); otherwise the sentence is skipped.
    private func ready(_ format: AVAudioFormat) -> Bool {
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else {
            onLog?("audio engine not running; sentence skipped")
            return false
        }
        connect(format)
        return true
    }

    private func started(_ item: Item, at start: CFTimeInterval) {
        recentText.append(item.sentence.text)
        if recentText.count > 6 { recentText.removeFirst() }
        lastSpokeAt = Date()
        onSentenceStart?(item.sentence)
        if item.first { onLog?(String(format: "voice: first audio %.2f s after the sentence", start - item.enqueued)) }
    }

    /// A streamed sentence being played: how far it is, and which cues still wait for their time.
    private final class Playback {
        let item: Item
        let stream: StreamedSpeech
        let generation: Int
        let start: CFTimeInterval
        let latency: TimeInterval
        var scheduled = 0
        var played = 0
        var done = false
        var untimed: [Int]

        init(item: Item, stream: StreamedSpeech, generation: Int, start: CFTimeInterval, latency: TimeInterval) {
            self.item = item
            self.stream = stream
            self.generation = generation
            self.start = start
            self.latency = latency
            untimed = Array(item.sentence.cues.indices)
        }
    }

    /// A sentence whose audio streams in: each piece is queued on the player as it arrives.
    private func playStreamed(_ item: Item, _ s: StreamedSpeech, generation gen: Int) {
        guard let format = s.buffers.first?.format, ready(format) else {
            s.cancel()
            if current === s { current = nil }
            busy = false
            pump()
            return
        }
        let start = CACurrentMediaTime()
        let p = Playback(item: item, stream: s, generation: gen, start: start, latency: AVAudioSession.sharedInstance().outputLatency)
        s.onChange = { [weak self] in self?.update(p) }
        update(p)
        player.play()
        started(item, at: start)
    }

    private func update(_ p: Playback) {
        guard p.generation == generation, !p.done else { return }
        let s = p.stream
        while p.scheduled < s.buffers.count {
            let b = s.buffers[p.scheduled]
            p.scheduled += 1
            player.scheduleBuffer(b, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, p.generation == self.generation else { return }
                    p.played += 1
                    self.update(p)
                }
            }
        }
        // A cue is timed once its word's time has arrived; at the end, the rest at the nearest
        // known time.
        let sentence = p.item.sentence
        p.untimed.removeAll { i in
            let cue = sentence.cues[i]
            let t = s.timing.knownStartTime(atUTF16: cue.anchor, in: sentence.text)
                ?? (s.finished ? (s.timing.startTime(atUTF16: cue.anchor, in: sentence.text) ?? 0) : nil)
            guard let t else { return false }
            let delay = max(0, p.start + t - Self.cueLead + p.latency - CACurrentMediaTime())
            let gen = p.generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, gen == self.generation else { return }
                self.onCue?(cue)
            }
            pendingCues.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return true
        }
        guard s.finished, p.played == p.scheduled else { return }
        p.done = true
        s.onChange = nil
        if current === s { current = nil }
        lastSpokeAt = Date()
        busy = false
        pump()
    }

    /// A sentence rendered whole (the iPhone's own voice).
    private func play(_ item: Item, _ rendered: RenderedSpeech?, generation gen: Int) {
        guard let rendered, let format = rendered.buffers.first?.format, ready(format) else {
            busy = false
            pump()
            return
        }
        let sentence = item.sentence
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
        started(item, at: CACurrentMediaTime())

        for cue in sentence.cues {
            let delay = max(0, rendered.time(cue.anchor) - Self.cueLead + latency)
            let work = DispatchWorkItem { [weak self] in
                guard let self, gen == self.generation else { return }
                self.onCue?(cue)
            }
            pendingCues.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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

/// A sentence's cloud speech as it streams in (main thread only).
final class StreamedSpeech {
    var buffers: [AVAudioPCMBuffer] = []
    /// The start time of each character received so far (no audio kept here).
    var timing = SpeechTiming()
    var finished = false
    var task: Task<Void, Never>?
    var onChange: (() -> Void)?

    func changed() { onChange?() }

    func cancel() {
        task?.cancel()
        onChange = nil
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
