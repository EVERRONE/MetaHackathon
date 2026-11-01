import ARKit
import AVFoundation
import Foundation

/// A test clip of what the camera saw, to replay object tracking on the Mac: 15 s of the camera's
/// own frames at 30 fps (HEVC, the sensor's full image, as ARKit delivers it), and per frame the
/// camera's pose, intrinsics and time (frames.jsonl); the LiDAR depth every fourth frame (Float16,
/// 256×192). Part of the test record (Documents/clips, see Diagnostics). Started from the
/// settings, after a countdown to put the phone in place.
final class ClipRecorder {
    static let seconds: TimeInterval = 15
    static let countdown: TimeInterval = 5

    /// A line for the screen while a clip is armed or recording ("" when done).
    var onStatus: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var armed = false
    private var startsAt: TimeInterval = 0
    private var folder: URL?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstTime: TimeInterval?
    private var arFrames = 0
    private var recorded = 0
    private var lines: [String] = []
    private var lastSecond = -1

    /// Arms a clip: it starts after the countdown.
    func start() {
        guard !armed else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        guard let folder = Diagnostics.newRun(in: "clips", named: stamp, keep: 20) else {
            onLog?("clip: the test record is switched off")
            return
        }
        self.folder = folder
        armed = true
        startsAt = CACurrentMediaTime() + Self.countdown
        firstTime = nil
        arFrames = 0
        recorded = 0
        lines = []
        lastSecond = -1
    }

    /// Every camera frame.
    func frame(_ frame: ARFrame) {
        guard armed, let folder else { return }
        let now = CACurrentMediaTime()
        if now < startsAt {
            let left = Int((startsAt - now).rounded(.up))
            if left != lastSecond { lastSecond = left; onStatus?("clip: starts in \(left) s") }
            return
        }
        if writer == nil, !setUp(frame, in: folder) {
            armed = false
            onStatus?("")
            return
        }
        arFrames += 1
        // ARKit gives 60 frames a second: every other one.
        guard arFrames % 2 == 1, let input, let adaptor else { return }
        let t0 = firstTime ?? frame.timestamp
        firstTime = t0
        let t = frame.timestamp - t0
        if input.isReadyForMoreMediaData, adaptor.append(frame.capturedImage, withPresentationTime: CMTime(seconds: t, preferredTimescale: 6000)) {
            let index = recorded
            recorded += 1
            let pose = ARController.values(frame.camera.transform)
            let k = frame.camera.intrinsics
            let intrinsics = [k.columns.0, k.columns.1, k.columns.2].flatMap { [$0.x, $0.y, $0.z] }
            let size = frame.camera.imageResolution
            var depthFile = ""
            if index % 4 == 0, let depth = frame.sceneDepth?.depthMap, let data = Self.float16(depth) {
                depthFile = String(format: "depth-%04d.f16", index)
                let url = folder.appendingPathComponent(depthFile)
                Diagnostics.write(to: url) { data }
            }
            let tracking: String
            switch frame.camera.trackingState {
            case .normal: tracking = "normal"
            case .limited(let reason): tracking = "limited \(reason)"
            case .notAvailable: tracking = "none"
            }
            let line: [String: Any] = ["i": index, "t": t, "pose": pose, "intrinsics": intrinsics, "w": size.width, "h": size.height,
                                       "depth": depthFile, "tracking": tracking]
            if let json = try? JSONSerialization.data(withJSONObject: line), let s = String(data: json, encoding: .utf8) { lines.append(s) }
        }
        let second = Int(t)
        if second != lastSecond {
            lastSecond = second
            onStatus?("clip: recording \(Int(Self.seconds) - second) s")
        }
        if t >= Self.seconds { finish() }
    }

    private func setUp(_ frame: ARFrame, in folder: URL) -> Bool {
        let w = CVPixelBufferGetWidth(frame.capturedImage), h = CVPixelBufferGetHeight(frame.capturedImage)
        guard let writer = try? AVAssetWriter(outputURL: folder.appendingPathComponent("video.mov"), fileType: .mov) else {
            onLog?("clip: cannot write a video")
            return false
        }
        // A high rate, so the fine texture the tracker follows survives the compression.
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else {
            onLog?("clip: \(writer.error.map { "\($0)" } ?? "cannot start")")
            return false
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        return true
    }

    private func finish() {
        armed = false
        guard let writer, let input, let folder else { return }
        let lines = lines, count = recorded
        self.writer = nil
        self.input = nil
        self.adaptor = nil
        input.markAsFinished()
        Diagnostics.write(to: folder.appendingPathComponent("frames.jsonl")) { Data((lines.joined(separator: "\n") + "\n").utf8) }
        let log = onLog
        writer.finishWriting {
            log?("clip: saved \(folder.lastPathComponent), \(count) frames (\(writer.status == .completed ? "complete" : "status \(writer.status.rawValue)"))")
        }
        onStatus?("")
    }

    /// The depth map as Float16, row by row.
    private static func float16(_ buffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        var out = [Float16](repeating: 0, count: w * h)
        for y in 0..<h {
            let p = (base + y * row).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { out[y * w + x] = Float16(p[x]) }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
