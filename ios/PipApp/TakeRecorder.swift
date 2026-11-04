import AVFAudio
import AVFoundation
import Foundation
import QuartzCore
import ReplayKit
import UIKit

/// Takes for the demo video, recorded by Pip itself. iOS's own screen recording has no sound with
/// Pip (voice processing keeps a call's audio out of it) and shows the red dot; a take has both
/// voices and only Pip's own screen:
/// - the screen through ReplayKit inside the app (no status bar, no recording dot), HEVC, 30 fps;
/// - Pip's voice as it is played: a tap on the mixer, digital, without the room;
/// - the microphone after voice processing: the user, without Pip's voice;
/// all from the take's first frame on the phone's one clock (a gap is filled with silence), and
/// what was said, shown and decided when (take.json).
///
/// A take runs while "Record takes" is on and the camera view is up: from closing the settings
/// until opening them again or leaving Pip. Each is a folder in Documents/takes, put together on
/// the Mac by scripts/takes.swift. Off, nothing runs and nothing is tapped.
final class TakeRecorder: ObservableObject {
    static let key = "pip.recordTakes"
    static var folder: URL { Diagnostics.documents.appendingPathComponent("takes") }
    /// Frames per second written (the screen draws up to 60).
    static let fps: Double = 30
    /// HEVC at the screen's own size: the camera image and the outlines stay sharp.
    static let bitRate = 16_000_000
    /// Room for two long takes (a 5-minute take is about 700 MB).
    static let minimumFree: Int64 = 1_500_000_000

    @Published private(set) var recording = false
    /// The last take saved, or what went wrong.
    @Published private(set) var status = ""
    /// Takes on this iPhone, and their size.
    @Published private(set) var count = 0
    @Published private(set) var bytes: Int64 = 0

    var onLog: ((String) -> Void)?
    /// The audio engine: it taps Pip's voice only while a take runs.
    weak var audio: AudioIO?

    private let queue = DispatchQueue(label: "pip.takes", qos: .userInitiated)
    private let lock = NSLock()
    /// Set while a take runs; read from any thread (log lines, audio).
    private var on = false
    /// The take's first frame is written.
    private var framed = false
    /// The take being written (only on `queue`).
    private var take: Take?
    private var pendingStart: DispatchWorkItem?
    /// ReplayKit's capture is being stopped (main thread): a start waits for it. On 4 Nov, Pip left
    /// and opened again within two seconds; the new start came while the old capture was still on,
    /// was refused ("already in recording state"), and the take was lost.
    private var stopping = false
    private var startAfterStop = false
    /// How often a start may still stop a capture left on and try again (each time Pip is opened).
    private var restarts = 0

    // MARK: Starting and ending (main thread)

    /// Records while `wanted` (the switch on, the settings closed, Pip in front). A start waits a
    /// moment, so the sheet sliding away is not in the take.
    func want(_ wanted: Bool) {
        pendingStart?.cancel()
        pendingStart = nil
        if wanted {
            guard !recording else { return }
            restarts = 2
            let work = DispatchWorkItem { [weak self] in self?.begin() }
            pendingStart = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        } else {
            startAfterStop = false
            if recording { end() }
        }
    }

    /// Calls `then` once the take shows its first frame, or after `seconds` (at once with 0): the
    /// launch picture waits for it, so a take started with Pip opens on it.
    func afterFirstFrame(within seconds: TimeInterval, _ then: @escaping () -> Void) {
        let deadline = CACurrentMediaTime() + seconds
        func poll() {
            if lock.withLock({ framed }) || CACurrentMediaTime() >= deadline { then(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
        }
        poll()
    }

    private func begin() {
        pendingStart = nil
        guard !recording else { return }
        // The last capture is still stopping, or ReplayKit still records one this recorder let go
        // (a start that was allowed after Pip had ended its take): first stopped, then this start.
        if stopping {
            startAfterStop = true
            return
        }
        if restarts > 0, RPScreenRecorder.shared().isRecording {
            restarts -= 1
            onLog?("take: the screen was still being recorded; stopped first")
            startAfterStop = true
            stopCapture()
            return
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let free = (try? Self.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           free < Self.minimumFree {
            status = "Not recording: less than 1.5 GB free on this iPhone."
            onLog?("take: not recording, \(free / 1_000_000) MB free on this iPhone")
            return
        }
        let name = Self.stamp()
        let dir = Self.folder.appendingPathComponent(name)
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            status = "Not recording: \(error.localizedDescription)"
            return
        }
        Diagnostics.excludeFromBackup(Self.folder)
        let take = Take(folder: dir, name: name)
        queue.sync { self.take = take }
        lock.withLock { on = true; framed = false }
        recording = true
        status = "Recording…"
        audio?.tape = self
        let screen = RPScreenRecorder.shared()
        screen.isMicrophoneEnabled = false
        screen.isCameraEnabled = false
        screen.startCapture(handler: { [weak self] sample, type, error in
            guard let self, error == nil, type == .video, CMSampleBufferDataIsReady(sample) else { return }
            let arrived = CACurrentMediaTime()
            self.queue.async {
                guard let take = self.take else { return }
                if take.video(sample, arrived: arrived) { self.lock.withLock { self.framed = true } }
            }
        }, completionHandler: { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.failed(error) }
        })
        onLog?("take: \(name) started")
    }

    /// Screen recording refused or failed: nothing is kept. Refused because a capture is still on:
    /// that one is stopped and this take started again, once.
    private func failed(_ error: Error) {
        guard recording else { return }
        end(discard: true)
        let e = error as NSError
        if restarts > 0, e.domain == RPRecordingErrorDomain, e.code == RPRecordingErrorCode.attemptToStartInRecordingState.rawValue {
            restarts -= 1
            onLog?("take: the screen was still being recorded; stopped, and started again")
            startAfterStop = true
            return
        }
        status = "Not recording: \(error.localizedDescription)"
        onLog?("take: screen recording failed: \(error.localizedDescription)")
    }

    /// Stops ReplayKit's capture; a start asked for meanwhile follows once it has stopped (or after
    /// three seconds without an answer).
    private func stopCapture() {
        stopping = true
        var settled = false
        let settle: () -> Void = { [weak self] in
            guard let self, !settled else { return }
            settled = true
            self.stopping = false
            if self.startAfterStop {
                self.startAfterStop = false
                self.begin()
            }
        }
        RPScreenRecorder.shared().stopCapture { _ in DispatchQueue.main.async(execute: settle) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: settle)
    }

    private func end(discard: Bool = false) {
        guard recording else { return }
        recording = false
        lock.withLock { on = false }
        audio?.tape = nil
        let take: Take? = queue.sync {
            let t = self.take
            self.take = nil
            t?.closing = true
            return t
        }
        stopCapture()
        guard let take else { return }
        if discard {
            queue.async { take.discard() }
            return
        }
        status = "Saving…"
        // Leaving Pip ends a take: it is finished in the background.
        let app = UIApplication.shared
        var background = UIBackgroundTaskIdentifier.invalid
        background = app.beginBackgroundTask(withName: "pip.take") {
            app.endBackgroundTask(background)
            background = .invalid
        }
        queue.async {
            take.finish { summary in
                DispatchQueue.main.async { [weak self] in
                    self?.status = summary
                    self?.onLog?("take: \(summary)")
                    self?.refresh()
                    if background != .invalid { app.endBackgroundTask(background) }
                }
            }
        }
    }

    // MARK: What goes into a take (any thread)

    /// A piece of audio: "mic" (AudioIO's microphone tap) or "pip" (the mixer).
    func audio(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime, stream: String) {
        guard lock.withLock({ on }), let copy = Self.slice(buffer, from: 0) else { return }
        let host = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil
        queue.async { [weak self] in self?.take?.audio(copy, host: host, stream: stream) }
    }

    /// What was said, shown or decided, at its time in the take: "pip" (a sentence as its voice
    /// starts), "you" (a final transcript), "echo" (one that was Pip's own voice), "you.start" and
    /// "you.end" (the speech service hearing the user begin and stop), "cue" (an outline shown),
    /// "log" (the session log).
    func note(_ kind: String, _ text: String) {
        guard lock.withLock({ on }) else { return }
        let now = CACurrentMediaTime()
        queue.async { [weak self] in self?.take?.events.append(.init(host: now, kind: kind, text: text)) }
    }

    // MARK: The takes on this iPhone

    func refresh() {
        let folder = Self.folder
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let takes = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter(\.hasDirectoryPath)
            var total: Int64 = 0
            for take in takes {
                for file in (try? fm.contentsOfDirectory(at: take, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                    total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.count = takes.count
                self?.bytes = total
            }
        }
    }

    func deleteAll() {
        guard !recording else { return }
        let folder = Self.folder
        queue.async { [weak self] in
            try? FileManager.default.removeItem(at: folder)
            DispatchQueue.main.async {
                self?.status = ""
                self?.refresh()
            }
        }
    }

    // MARK: Helpers

    static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f.string(from: Date())
    }

    /// The frames of `b` from `start` on, in a buffer of their own (a tap's buffer is reused).
    static func slice(_ b: AVAudioPCMBuffer, from start: Int) -> AVAudioPCMBuffer? {
        let n = Int(b.frameLength) - start
        guard n > 0, let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        out.frameLength = AVAudioFrameCount(n)
        let bytesPerFrame = Int(b.format.streamDescription.pointee.mBytesPerFrame)
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: b.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sp = s.mData, let dp = d.mData else { continue }
            memcpy(dp, sp.advanced(by: start * bytesPerFrame), n * bytesPerFrame)
        }
        return out
    }
}

/// One take being written (only on the recorder's queue).
private final class Take {
    struct Event {
        var host: Double
        var kind: String
        var text: String
    }

    let folder: URL
    let name: String
    let started = Date()
    var closing = false
    var events: [Event] = []
    /// The host time of the first frame: zero in every file of the take.
    private var t0: Double?
    /// ReplayKit's frame times are on the host clock (each arrives a few ms after it); if not,
    /// they are moved onto it by the first frame's arrival.
    private var ptsOffset: Double = 0
    private var lag = Double.infinity
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var startFailed = false
    private var size = CGSize.zero
    private var lastFrame = -Double.infinity
    private var frames = 0
    private var dropped = 0
    private var streams: [String: AudioStream] = [:]
    private var problems: [String] = []
    private let latency: [String: Double]

    init(folder: URL, name: String) {
        self.folder = folder
        self.name = name
        let s = AVAudioSession.sharedInstance()
        latency = ["input": s.inputLatency, "output": s.outputLatency, "ioBuffer": s.ioBufferDuration]
    }

    /// A screen frame; true once the take has frames.
    func video(_ sample: CMSampleBuffer, arrived: Double) -> Bool {
        guard !closing else { return false }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid else { return false }
        if writer == nil {
            guard !startFailed else { return false }
            let gap = arrived - pts.seconds
            ptsOffset = abs(gap) < 1 ? 0 : gap
            guard start(with: sample, at: pts) else {
                startFailed = true
                return false
            }
        }
        lag = min(lag, arrived - pts.seconds - ptsOffset)
        let t = pts.seconds + ptsOffset
        guard t - lastFrame >= 1 / TakeRecorder.fps - 0.004 else { return frames > 0 }
        guard let writer, let input, writer.status == .writing, input.isReadyForMoreMediaData else {
            dropped += 1
            return frames > 0
        }
        if input.append(sample) {
            lastFrame = t
            frames += 1
        } else if problems.count < 5 {
            problems.append("frame not written: \(writer.error?.localizedDescription ?? "?")")
        }
        return frames > 0
    }

    private func start(with sample: CMSampleBuffer, at pts: CMTime) -> Bool {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return false }
        // Even sides for the encoder (the screen is 1179 wide).
        let w = CVPixelBufferGetWidth(pixels) & ~1, h = CVPixelBufferGetHeight(pixels) & ~1
        do {
            let writer = try AVAssetWriter(outputURL: folder.appendingPathComponent("screen.mov"), fileType: .mov)
            // Written in fragments: a take cut short (a crash) still plays up to the last one.
            writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: TakeRecorder.bitRate,
                    AVVideoExpectedSourceFrameRateKey: Int(TakeRecorder.fps),
                    AVVideoMaxKeyFrameIntervalKey: Int(TakeRecorder.fps) * 2,
                    AVVideoAllowFrameReorderingKey: false,
                ] as [String: Any],
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                problems.append("cannot add the video")
                return false
            }
            writer.add(input)
            guard writer.startWriting() else {
                problems.append("cannot write: \(writer.error?.localizedDescription ?? "?")")
                return false
            }
            writer.startSession(atSourceTime: pts)
            self.writer = writer
            self.input = input
            size = CGSize(width: w, height: h)
            t0 = pts.seconds + ptsOffset
            return true
        } catch {
            problems.append("cannot write: \(error.localizedDescription)")
            return false
        }
    }

    /// Audio, placed by its host time: sample 0 is the first frame. Before it, nothing.
    func audio(_ buffer: AVAudioPCMBuffer, host: Double?, stream name: String) {
        guard !closing, let t0 else { return }
        let stream: AudioStream
        if let s = streams[name] {
            stream = s
        } else {
            do {
                stream = try AudioStream(url: folder.appendingPathComponent("\(name).caf"), format: buffer.format)
            } catch {
                if problems.count < 5 { problems.append("\(name): \(error.localizedDescription)") }
                return
            }
            streams[name] = stream
        }
        stream.write(buffer, at: host.map { $0 - t0 })
    }

    func finish(_ done: @escaping (String) -> Void) {
        closing = true
        for s in streams.values { s.close() }
        let seconds = frames > 0 && t0 != nil ? lastFrame - t0! : 0
        writeSummary(seconds: seconds)
        guard let writer, let input, frames > 0 else {
            discard()
            done("Nothing recorded: no screen frames arrived. \(problems.first ?? "")")
            return
        }
        input.markAsFinished()
        writer.finishWriting { [self] in
            let ok = writer.status == .completed
            let missing = ["pip": "Pip's voice", "mic": "your voice"].filter { streams[$0.key] == nil }.map(\.value).sorted()
            var summary = String(format: "%@ saved: %d:%02d", name, Int(seconds) / 60, Int(seconds) % 60)
            if !ok { summary += ", the video failed (\(writer.error?.localizedDescription ?? "?"))" }
            if !missing.isEmpty { summary += ", without " + missing.joined(separator: " and ") }
            done(summary + ".")
        }
    }

    func discard() {
        closing = true
        for s in streams.values { s.close() }
        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: folder)
    }

    /// take.json: how the files line up, and every event at its time in the take.
    private func writeSummary(seconds: Double) {
        let base = t0 ?? 0
        let audio = streams.mapValues { $0.summary }
        let summary: [String: Any] = [
            "take": name,
            "started": ISO8601DateFormatter().string(from: started),
            "seconds": (seconds * 1000).rounded() / 1000,
            "video": ["file": "screen.mov", "frames": frames, "dropped": dropped, "width": Int(size.width), "height": Int(size.height),
                      "fps": TakeRecorder.fps, "arrivalLag": lag.isFinite ? (lag * 1000).rounded() / 1000 : -1, "clockMoved": ptsOffset] as [String: Any],
            "audio": audio,
            "latency": latency,
            "problems": problems,
            "events": events.map { ["t": (($0.host - base) * 1000).rounded() / 1000, "kind": $0.kind, "text": $0.text] as [String: Any] },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("take.json"))
        }
    }
}

/// One audio file of a take (16-bit), each piece written where its host time puts it.
private final class AudioStream {
    let file: AVAudioFile
    let rate: Double
    private(set) var written: AVAudioFramePosition = 0
    private var silence: AVAudioFramePosition = 0
    private var moves = 0
    private var failures = 0
    private var converter: AVAudioConverter?

    init(url: URL, format: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        rate = file.processingFormat.sampleRate
    }

    var summary: [String: Any] {
        ["rate": rate, "channels": Int(file.processingFormat.channelCount), "frames": Int(written),
         "silenceAdded": (Double(silence) / rate * 1000).rounded() / 1000, "moves": moves, "failures": failures]
    }

    /// `time`: seconds from the take's first frame (nil: right after the last piece). A piece
    /// within 20 ms of where the last one ended follows on (the clocks jitter); further off, the
    /// gap is filled with silence or the overlap left out.
    func write(_ b: AVAudioPCMBuffer, at time: Double?) {
        guard let b = matched(b) else { return }
        let n = AVAudioFramePosition(b.frameLength)
        guard n > 0 else { return }
        var skip: AVAudioFramePosition = 0
        if let time {
            let start = AVAudioFramePosition((time * rate).rounded())
            let tolerance = AVAudioFramePosition(rate * 0.02)
            if start + n <= written { return }
            if start > written + tolerance {
                pad(start - written)
                moves += 1
            } else if start < written - tolerance {
                skip = written - start
                moves += 1
            }
        }
        guard let piece = skip > 0 ? TakeRecorder.slice(b, from: Int(skip)) : b else { return }
        do {
            try file.write(from: piece)
            written += AVAudioFramePosition(piece.frameLength)
        } catch {
            failures += 1
        }
    }

    func close() { file.close() }

    private func pad(_ frames: AVAudioFramePosition) {
        let chunk = AVAudioFrameCount(rate)
        guard let zero = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return }
        zero.frameLength = chunk
        for b in UnsafeMutableAudioBufferListPointer(zero.mutableAudioBufferList) {
            if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) }
        }
        var left = frames
        while left > 0 {
            zero.frameLength = AVAudioFrameCount(min(left, AVAudioFramePosition(chunk)))
            do { try file.write(from: zero) } catch { failures += 1; return }
            left -= AVAudioFramePosition(zero.frameLength)
            written += AVAudioFramePosition(zero.frameLength)
            silence += AVAudioFramePosition(zero.frameLength)
        }
    }

    /// The file's own format (a route change may bring another rate or channel layout).
    private func matched(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = file.processingFormat
        if b.format == target { return b }
        if converter == nil || converter?.inputFormat != b.format { converter = AVAudioConverter(from: b.format, to: target) }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(b.frameLength) * target.sampleRate / b.format.sampleRate + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return b
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}
