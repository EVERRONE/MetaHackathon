import ARKit
import Vision
import simd

/// Follows the object EdgeTAM steers in every second camera frame with Apple Vision's object
/// tracker, so a moving object's outline keeps up between EdgeTAM's masks.
///
/// A mask is 0.15–0.25 s old when it arrives (more when the iPhone is warm: 6 masks a second on
/// 1 Nov), and an object in the hand moves several centimetres in that time; a simulation with the
/// measured timing put the outline 2–5 cm behind a moving object. The tracker's view of a frame
/// arrives a few hundredths of a second after it. Its displacement since the mask's frame moves
/// the mask's outline to where the object is on the frame shown (ARController.renderNow). It only
/// counts while the object moves: a still one is drawn from its masks alone, so the tracker's own
/// jitter never shows. It is started where EdgeTAM sees the object, and started again when the two
/// disagree.
final class FastFollow {
    static let rate: TimeInterval = 1.0 / 30
    /// Samples kept, seconds.
    static let keep: TimeInterval = 1.5

    private let queue = DispatchQueue(label: "pip.fastfollow", qos: .userInitiated)
    private let tracker = Tracker()
    private var busy = false
    private var lastRun: TimeInterval = 0
    /// Where to start on the next frame: the object's outline in the room, its velocity and the
    /// time of the mask it comes from.
    private var pendingStart: (outline: [simd_float3], velocity: simd_float3, time: TimeInterval)?
    private(set) var running = false
    private var generation = 0
    private var weakFrames = 0
    /// The tracked box centre in the room, per camera frame (at the object's depth from EdgeTAM).
    private(set) var samples: [(t: TimeInterval, p: simd_float3)] = []
    /// The object's distance from the camera along its axis, from EdgeTAM's latest mask.
    var depth: Float?

    // For the log.
    private(set) var runs = 0
    private(set) var weak = 0
    private(set) var starts = 0
    private var millis: [Double] = []

    /// Starts (again) on the next camera frame where the object is then: `outline` (room) moved
    /// on by `velocity` from `time`, projected into that frame.
    func start(outline: [simd_float3], velocity: simd_float3, time: TimeInterval) {
        pendingStart = (outline, velocity, time)
    }

    func stop() {
        pendingStart = nil
        running = false
        generation += 1
        samples = []
        let tracker = tracker
        queue.async { tracker.stop() }
    }

    /// Every camera frame.
    func frame(_ frame: ARFrame) {
        let t = frame.timestamp
        guard !busy, t - lastRun >= Self.rate, let depth else { return }
        var box: CGRect?
        if let start = pendingStart {
            pendingStart = nil
            let moved = start.outline.map { $0 + start.velocity * Float(max(0, t - start.time)) }
            guard let b = Self.visionBox(moved, camera: frame.camera), b.width > 0.004, b.height > 0.004 else { return }
            box = b
            samples = []
            running = true
            weakFrames = 0
            starts += 1
            generation += 1
        }
        guard running else { return }
        busy = true
        lastRun = t
        let me = generation
        let buffer = frame.capturedImage
        let camera = frame.camera
        let tracker = tracker
        queue.async { [weak self] in
            let t0 = CACurrentMediaTime()
            if let box { tracker.start(box) }
            let result = tracker.track(buffer)
            let ms = (CACurrentMediaTime() - t0) * 1000
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard self.generation == me else { return }
                self.runs += 1
                self.millis.append(ms)
                if self.millis.count > 90 { self.millis.removeFirst(self.millis.count - 90) }
                guard let (b, confidence) = result, confidence >= 0.3 else {
                    self.weak += 1
                    self.weakFrames += 1
                    // Lost: no displacement until EdgeTAM starts it again.
                    if self.weakFrames >= 3 { self.running = false; self.samples = [] }
                    return
                }
                self.weakFrames = 0
                // Vision's (x, y) are sensor x and 1 − sensor y; upright (u, v) is sensor (v, 1 − u).
                let centre = CGPoint(x: b.midY, y: b.midX)
                let p = Self.lift(centre, depth: depth, camera: camera)
                self.samples.append((t, p))
                self.samples.removeAll { t - $0.t > Self.keep }
            }
        }
    }

    /// Where the tracker had the object at `time`, between two of its samples.
    func position(at time: TimeInterval) -> simd_float3? {
        guard let first = samples.first, let last = samples.last, time >= first.t - 0.02, time <= last.t + 0.02 else { return nil }
        if time <= first.t { return first.p }
        if time >= last.t { return last.p }
        for (a, b) in zip(samples, samples.dropFirst()) where a.t <= time && time <= b.t {
            let w = Float((time - a.t) / max(b.t - a.t, 1e-6))
            return a.p + (b.p - a.p) * w
        }
        return nil
    }

    /// The tracker's velocity over its last ~0.12 s (least squares), m/s.
    var velocity: simd_float3? {
        guard let last = samples.last else { return nil }
        let recent = samples.filter { last.t - $0.t <= 0.12 }
        guard recent.count >= 3 else { return nil }
        let mt = recent.map(\.t).reduce(0, +) / Double(recent.count)
        let mp = recent.map(\.p).reduce(simd_float3.zero, +) / Float(recent.count)
        var num = simd_float3.zero
        var den: Float = 0
        for s in recent {
            let dt = Float(s.t - mt)
            num += (s.p - mp) * dt
            den += dt * dt
        }
        return den > 0 ? num / den : nil
    }

    /// How far the object moved from the frame of `since` (a mask's) to the frame shown at
    /// `shown`, and how fast it moves now. nil without samples around both.
    func shift(since: TimeInterval, to shown: TimeInterval) -> (shift: simd_float3, speed: Float)? {
        guard running, let base = position(at: since), let last = samples.last, let v = velocity else { return nil }
        let ahead = Float(min(max(0, shown - last.t), 0.1))
        return (last.p + v * ahead - base, simd_length(v))
    }

    var summary: String {
        let s = millis.sorted()
        return String(format: "%d frames, %.1f ms median, %d weak, %d starts", runs, s.isEmpty ? 0 : s[s.count / 2], weak, starts)
    }

    // MARK: Coordinates

    /// The box round `points` (room) in a frame, in Vision's terms: normalised sensor image, origin
    /// bottom left. nil if any point is behind the camera.
    static func visionBox(_ points: [simd_float3], camera: ARCamera) -> CGRect? {
        let size = camera.imageResolution, k = camera.intrinsics
        let inverse = simd_inverse(camera.transform)
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for p in points {
            let q = inverse * simd_float4(p, 1)
            guard q.z < -0.03 else { return nil }
            let z = -q.z
            let px = CGFloat(k[2][0] + k[0][0] * q.x / z) / size.width
            let py = CGFloat(k[2][1] - k[1][1] * q.y / z) / size.height
            minX = min(minX, px); maxX = max(maxX, px); minY = min(minY, 1 - py); maxY = max(maxY, 1 - py)
        }
        guard minX.isFinite else { return nil }
        let box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let clipped = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return clipped.isNull ? nil : clipped
    }

    /// An upright normalised point at camera depth `d`, in the room.
    static func lift(_ p: CGPoint, depth d: Float, camera: ARCamera) -> simd_float3 {
        let size = camera.imageResolution, k = camera.intrinsics, t = camera.transform
        // Upright (u, v) is sensor (v, 1 − u).
        let px = Float(p.y) * Float(size.width), py = Float(1 - p.x) * Float(size.height)
        let x = (px - k[2][0]) / k[0][0] * d, y = -(py - k[2][1]) / k[1][1] * d
        let w = t * simd_float4(x, y, -d, 1)
        return simd_float3(w.x, w.y, w.z)
    }
}

/// Vision's tracker, used on FastFollow's queue only. A tracker is released by a last frame with
/// `isLastFrame` set; Vision refuses new trackers while too many are held.
private final class Tracker: @unchecked Sendable {
    private let handler = VNSequenceRequestHandler()
    private var request: VNTrackObjectRequest?
    private var finishing: [VNTrackObjectRequest] = []

    func start(_ box: CGRect) {
        if let old = request { finishing.append(old) }
        let r = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box))
        r.trackingLevel = .accurate
        request = r
    }

    func stop() {
        if let old = request { finishing.append(old) }
        request = nil
    }

    func track(_ buffer: CVPixelBuffer) -> (CGRect, Float)? {
        let done = finishing
        finishing = []
        for r in done { r.isLastFrame = true }
        let active = request.map { [$0] } ?? []
        guard !active.isEmpty || !done.isEmpty else { return nil }
        do { try handler.perform(active + done, on: buffer, orientation: .up) } catch { return nil }
        guard let r = request, let obs = r.results?.first as? VNDetectedObjectObservation else { return nil }
        r.inputObservation = obs
        return (obs.boundingBox, obs.confidence)
    }
}
