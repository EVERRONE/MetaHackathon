import AVFAudio
import Foundation

/// One audio engine for the microphone and Pip's voice, with Apple's voice processing on, so the
/// microphone hears the user but not Pip (echo cancellation). That is what makes barge-in work.
final class AudioIO {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    /// 16 kHz mono 16-bit little-endian chunks, as the live transcription expects.
    var onPCM: ((Data) -> Void)?
    /// When muted, silence is sent instead of the microphone, which keeps the live session open.
    var muted = false

    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var running = false

    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)

        let inFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inFormat, to: target) else { throw AudioError.format }
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let data = self.convert(buffer, with: converter) else { return }
            self.onPCM?(self.muted ? Data(count: data.count) : data)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
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
