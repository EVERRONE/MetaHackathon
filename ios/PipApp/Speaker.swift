import AVFAudio
import Foundation
import PipCore
import QuartzCore

/// Speaks sentences and fires each cue just before the word it belongs to.
///
/// Each sentence is synthesised to PCM buffers with word markers, then played through an
/// AVAudioEngine. A marker's `byteSampleOffset` is a byte offset into the synthesised audio
/// (measured: 4 bytes per Float32 frame), so word time = offset / bytesPerFrame / sampleRate.
final class Speaker {
    /// Research: show a cue 300–800 ms before the noun it goes with.
    static let cueLead: TimeInterval = 0.4

    var voice: AVSpeechSynthesisVoice?
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var onSentenceStart: ((SpokenSentence) -> Void)?
    var onCue: ((TimedCue) -> Void)?
    var onIdle: (() -> Void)?

    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playerFormat: AVAudioFormat?
    private var queue: [SpokenSentence] = []
    private var busy = false
    private var generation = 0
    private var pendingCues: [DispatchWorkItem] = []

    init() {
        engine.attach(player)
    }

    var isSpeaking: Bool { busy || !queue.isEmpty }

    func enqueue(_ sentence: SpokenSentence) {
        queue.append(sentence)
        pump()
    }

    /// Stops at once (barge-in): audio, queued sentences and cues that have not fired yet.
    func stop() {
        generation += 1
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
        let sentence = queue.removeFirst()
        let gen = generation
        synthesize(sentence.text) { [weak self] buffers, markers in
            guard let self, gen == self.generation else { return }
            self.play(sentence, buffers: buffers, markers: markers, generation: gen)
        }
    }

    private final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var buffers: [AVAudioPCMBuffer] = []
        var markers: [AVSpeechSynthesisMarker] = []
        var done = false
    }

    private func synthesize(_ text: String, completion: @escaping ([AVAudioPCMBuffer], [AVSpeechSynthesisMarker]) -> Void) {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = rate
        let c = Collector()
        synth.write(u, toBufferCallback: { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            c.lock.lock()
            defer { c.lock.unlock() }
            guard !c.done else { return }
            if pcm.frameLength == 0 {
                c.done = true
                let (b, m) = (c.buffers, c.markers)
                DispatchQueue.main.async { completion(b, m) }
            } else {
                c.buffers.append(pcm)
            }
        }, toMarkerCallback: { markers in
            c.lock.lock()
            c.markers += markers
            c.lock.unlock()
        })
    }

    private func play(_ sentence: SpokenSentence, buffers: [AVAudioPCMBuffer], markers: [AVSpeechSynthesisMarker], generation gen: Int) {
        guard let format = buffers.first?.format else {
            busy = false
            pump()
            return
        }
        connect(format)

        let bytesPerFrame = Double(format.streamDescription.pointee.mBytesPerFrame)
        let words = markers.filter { $0.mark == .word }.map { (location: $0.textRange.location, time: Double($0.byteSampleOffset) / bytesPerFrame / format.sampleRate) }

        for (i, b) in buffers.enumerated() {
            let last = i == buffers.count - 1
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
        onSentenceStart?(sentence)

        for cue in sentence.cues {
            // The word that starts at (or first after) the cue's anchor.
            let t = words.first(where: { $0.location >= cue.anchor })?.time ?? words.last?.time ?? 0
            let delay = max(0, t - Self.cueLead + latency)
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

    /// The best installed voice for a language: premium, then enhanced, then default.
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
