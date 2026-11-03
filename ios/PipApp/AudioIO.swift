import AVFAudio
import Foundation
import PipCore

/// One audio engine for the microphone and Pip's voice, with Apple's voice processing on, so the
/// microphone hears the user but not Pip (echo cancellation). That is what makes barge-in work.
///
/// The engine restarts itself after a route change (AirPods, a car) or an interruption (a call,
/// Siri), so Pip does not go deaf.
final class AudioIO {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    var onRestartFailed: ((Error) -> Void)?

    /// Where the 16 kHz microphone audio goes. Read on the audio thread, so behind a lock.
    var sink: RealtimeTranscriber? {
        get { lock.withLock { _sink } }
        set { lock.withLock { _sink = newValue } }
    }

    /// When muted, silence is sent instead of the microphone, which keeps the live session open.
    var muted: Bool {
        get { lock.withLock { _muted } }
        set { lock.withLock { _muted = newValue } }
    }

    /// The take being recorded for the demo video (TakeRecorder): the microphone after voice
    /// processing goes there too, and Pip's voice from a tap on the mixer, only while a take
    /// runs. Set on the main thread.
    var tape: TakeRecorder? {
        get { lock.withLock { _tape } }
        set {
            lock.withLock { _tape = newValue }
            tapMixer()
        }
    }

    private let lock = NSLock()
    private var _sink: RealtimeTranscriber?
    private var _muted = false
    private var _tape: TakeRecorder?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var running = false
    private var observers: [NSObjectProtocol] = []

    func start() throws {
        guard !running else { return }
        try engine.inputNode.setVoiceProcessingEnabled(true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        try startEngine()
        running = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.ended.rawValue { self?.restart() }
        })
    }

    /// Installs the microphone tap for the current input format and starts the engine.
    private func startEngine() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let converter = AVAudioConverter(from: inFormat, to: target) else { throw AudioError.format }
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, when in
            guard let self else { return }
            let (sink, muted, tape) = self.lock.withLock { (self._sink, self._muted, self._tape) }
            // A take hears the user also while Pip does not listen.
            tape?.audio(buffer, at: when, stream: "mic")
            guard let data = self.convert(buffer, with: converter) else { return }
            sink?.send(pcm: muted ? Data(count: data.count) : data)
        }
        engine.prepare()
        try engine.start()
        tapMixer()
    }

    /// Pip's voice as it is played (the player is all the mixer has), for a take; no tap without one.
    private func tapMixer() {
        guard engine.isRunning || running else { return }
        let mixer = engine.mainMixerNode
        mixer.removeTap(onBus: 0)
        guard lock.withLock({ _tape != nil }) else { return }
        mixer.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, when in
            guard let self, let tape = self.lock.withLock({ self._tape }) else { return }
            tape.audio(buffer, at: when, stream: "pip")
        }
    }

    private func restart() {
        guard running else { return }
        engine.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try startEngine()
        } catch {
            onRestartFailed?(error)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> Data? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(out.frameLength) * 2)
    }

    enum AudioError: Error { case format }
}
