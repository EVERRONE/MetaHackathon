import ARKit
import CoreImage
import ImageIO
import PipCore
import UIKit
import UniformTypeIdentifiers

/// Meta's EdgeTAM follows the latest pointed-at object live on the Neural Engine, and Pip's outline
/// is drawn from its mask: the mask's outline lifted into the room at the object's raw LiDAR depth,
/// renewed about ten times a second, and moved with ARKit's camera in between (see
/// ARController.steer). An object that moved and is no longer seen loses its outline until it is
/// seen again. The device test (spike T1, docs/research-precision.md): EdgeTAM agreed with SAM 3.1
/// on every kept frame about whether the object was in view, box IoU 0.87–0.94, at 9–10 fps.
/// Per frame a line in Documents/edgetam.log; every second a frame with its mask in
/// Documents/edgetam/<start>/, to compare with SAM 3.1 on the Mac. One object at a time.
final class EdgeTAMSpike {
    static let enabledKey = "pip.edgetamSpike"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    /// EdgeTAM's own mask drawn in cyan as well (for tests).
    static let maskKey = "pip.edgetamMask"
    static var showMask: Bool { UserDefaults.standard.bool(forKey: maskKey) }

    static let followFor: TimeInterval = 600
    /// Moved this far in the last half second: a moving object, hidden when it is lost.
    static let movingDistance: Float = 0.02
    /// Folders of kept frames beyond this many runs are deleted.
    static let keepRuns = 10
    static let keepEvery: TimeInterval = 1
    static let maxKept = 90

    /// Over the camera image, under Pip's own outlines.
    let view = UIView()
    private let maskLayer = CALayer()
    var onStatus: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    /// The object's outline in the room (world space), from this frame's mask, with the object's
    /// velocity (m/s, zero when still) and the frame's time.
    var onOutline: ((Int, [[simd_float3]], simd_float3, TimeInterval) -> Void)?
    /// Not seen in this frame; `moving`: it moved just before.
    var onLost: ((Int, Bool) -> Void)?
    /// Whether an image lock saw this mark's object face recently (ARController).
    var lockHeld: ((Int) -> Bool)?
    /// A comparison of the shown outline with this frame's mask, in mm, and whether the object
    /// moved (ARController checks image locks against it).
    var onShownCheck: ((Int, Double, Bool, Bool) -> Void)?
    /// EdgeTAM's object score above which its mask may overrule an image lock (on 1 Nov a remote's
    /// POWER button scored 8-10, a mask that was wrong 3.2-3.8).
    static let sureScore: Float = 6
    /// Where the outline was drawn on the camera frame of a given time, if it was (ARController):
    /// what the user saw, to compare with where the mask of that same frame finds the object.
    var drawnAt: ((Int, TimeInterval) -> simd_float3?)?
    private var centres: [(t: TimeInterval, p: simd_float3)] = []

    private let worker = EdgeTAMWorker()
    /// Follows the object between masks, for a moving object's outline (see FastFollow).
    let fast = FastFollow()
    /// The last mask taken: its frame's time and its outline's centre, to see whether the fast
    /// tracker moved the same way as EdgeTAM between two masks.
    private var lastTaken: (t: TimeInterval, p: simd_float3)?
    /// Masks in a row on which the fast tracker disagreed with EdgeTAM.
    private var disagreements = 0
    private var lastFastStart: TimeInterval = 0
    /// Masks of frames from before this were lifted into the old room coordinates.
    private var coordinatesMovedAt: TimeInterval = 0
    private(set) var markID: Int?
    private var run = 0
    private var seeded = false
    private var busy = false
    private var startedAt: TimeInterval = 0
    private var folder: URL?
    private var kept = 0
    private var lastKept: TimeInterval = 0
    private var arTimes: [TimeInterval] = []
    private var doneTimes: [TimeInterval] = []
    private var totals: [Double] = []
    private var lastStatus: TimeInterval = 0

    init() {
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        maskLayer.magnificationFilter = .nearest
        view.layer.addSublayer(maskLayer)
    }

    /// Loads the models at start (the first load on a phone also compiles them for the Neural
    /// Engine, several seconds), so the first pointed-at object is followed at once.
    func preload() {
        worker.load { [weak self] result in
            switch result {
            case .success(let seconds):
                self?.log(String(format: "edgetam: models loaded in %.1f s", seconds))
                Self.append(String(format: "%@\tload\t%.2f\n", Self.now(), seconds))
            case .failure(let e):
                self?.log("edgetam: cannot load: \(e)")
            }
        }
    }

    /// Follows the object of a mark just placed from `snapshot` (`instance` in its pixels).
    func start(markID: Int, snapshot: FrameSnapshot, instance: SegmentInstance, phrase: String?) {
        stop(reason: "a new object")
        run += 1
        let me = run
        self.markID = markID
        seeded = false
        busy = true
        startedAt = CACurrentMediaTime()
        kept = 0
        lastKept = 0
        totals = []
        doneTimes = []
        centres = []
        smoothedVelocity = .zero
        lastDrawn = nil
        checks = []
        shownChecks = []
        rejected = 0
        fast.stop()
        lastTaken = nil
        disagreements = 0
        Self.pruneRuns()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = Self.documents.appendingPathComponent("edgetam/\(stamp)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        let size = CGSize(width: snapshot.image.width, height: snapshot.image.height)
        let mask = EdgeTAM.Input.mask(polygons: instance.outlinePoints, in: size)
        // The seed, for comparing with SAM 3.1 later: the snapshot and SAM's own outline.
        Self.write(jpeg: snapshot.image, to: folder.appendingPathComponent("seed.jpg"))
        let meta: [String: Any] = ["mark": markID % 1000, "phrase": phrase ?? "", "box": instance.box, "polygons": instance.polygons,
                                   "size": [snapshot.image.width, snapshot.image.height]]
        try? JSONSerialization.data(withJSONObject: meta).write(to: folder.appendingPathComponent("seed.json"))
        status("EdgeTAM: loading…")
        worker.seed(image: snapshot.image, mask: mask) { [weak self] result in
            guard let self, self.run == me else { return }
            self.busy = false
            switch result {
            case .success(let r):
                self.seeded = true
                self.log(String(format: "edgetam: mark %d seeded in %.0f ms (models loaded in %.1f s), score %.1f", markID % 1000, r.ms, r.loadSeconds, r.frame.objectScore))
                Self.append(String(format: "%@\tseed\t%d\t%.1f\t%.1f\t%.2f\n", Self.now(), markID % 1000, r.ms, r.loadSeconds, r.frame.objectScore))
            case .failure(let e):
                self.markID = nil
                self.log("edgetam: cannot start: \(e)")
                self.status("EdgeTAM: \(e)")
            }
        }
    }

    func stop(reason: String) {
        guard let id = markID else { return }
        run += 1
        markID = nil
        fast.stop()
        seeded = false
        busy = false
        maskLayer.contents = nil
        if !totals.isEmpty {
            let sorted = totals.sorted()
            let span = (doneTimes.last ?? 0) - (doneTimes.first ?? 0)
            let line = String(format: "edgetam: mark %d stopped (%@): %d frames, median %.0f ms, p90 %.0f ms, %.1f fps, %d kept, heat %@",
                              id % 1000, reason, totals.count, sorted[sorted.count / 2], sorted[sorted.count * 9 / 10],
                              span > 0 ? Double(doneTimes.count - 1) / span : 0, kept, Self.heat())
            log(line)
            Self.append("\(Self.now())\tstop\t\(line)\n")
        }
        status("")
    }

    /// Every camera frame: ARKit's rate is counted, and the next frame goes to EdgeTAM as soon as
    /// the last one is done.
    func frame(_ frame: ARFrame, viewSize: CGSize, markExists: Bool) {
        let t = frame.timestamp
        arTimes.append(t)
        arTimes.removeAll { t - $0 > 1 }
        guard let id = markID else { return }
        guard markExists else { stop(reason: "outline gone"); return }
        guard CACurrentMediaTime() - startedAt < Self.followFor else { stop(reason: "time"); return }
        if seeded { fast.frame(frame) }
        guard seeded, !busy, viewSize.width > 0 else { return }
        busy = true
        let me = run
        let keep = kept < Self.maxKept && t - lastKept >= Self.keepEvery
        if keep { lastKept = t; kept += 1 }
        let index = kept
        let request = EdgeTAMWorker.Request(buffer: frame.capturedImage, depth: DepthCopy(frame.sceneDepth), camera: frame.camera, time: t,
                                            keep: keep ? folder?.appendingPathComponent(String(format: "%03d", index)) : nil,
                                            lockHeld: lockHeld?(id) ?? false)
        let display = frame.displayTransform(for: .portrait, viewportSize: viewSize)
        let arFps = arTimes.count
        worker.track(request) { [weak self] result in
            guard let self, self.run == me else { return }
            self.busy = false
            guard case .success(let r) = result else {
                if case .failure(let e) = result { self.log("edgetam: \(e)") }
                return
            }
            let done = CACurrentMediaTime()
            self.doneTimes.append(done)
            self.totals.append(r.ms)
            if Self.showMask { self.draw(r.frame, display: display, viewSize: viewSize) } else { self.maskLayer.contents = nil }
            self.steer(id, r, time: done)
            let recent = self.doneTimes.filter { done - $0 <= 1 }.count
            let f = r.frame
            let b = f.box ?? .zero
            Self.append(String(format: "%@\t%d\t%.1f\t%.1f\t%.1f\t%.1f\t%.2f\t%.3f\t%.5f\t%.4f\t%.4f\t%.4f\t%.4f\t%@\t%d\t%d\t%d\t%@\t%.3f\t%.1f\t%.1f\t%.1f\n",
                               Self.now(), id % 1000, r.prepMs, f.encodeMs, f.decodeMs, r.ms, f.objectScore, f.iou, f.area,
                               b.minX, b.minY, b.maxX, b.maxY,
                               r.world.map { String(format: "%.4f,%.4f,%.4f", $0.x, $0.y, $0.z) } ?? "-", r.depthSamples, arFps, recent,
                               // ARKit's frame times run on the same clock as CACurrentMediaTime.
                               Self.heat(), done - r.time, f.bankMs, f.propagateMs, f.readMs))
            if done - self.lastStatus > 0.25 {
                self.lastStatus = done
                self.status(String(format: "EdgeTAM %d fps · %.0f ms · score %.1f · AR %d fps · %@", recent, r.ms, f.objectScore, arFps, Self.heat()))
            }
        }
    }

    /// Pip's outline follows the mask; when the object is not seen, it waits where it was, unless
    /// it was moving (then it is hidden until seen again).
    private func steer(_ id: Int, _ r: EdgeTAMWorker.Tracked, time: TimeInterval) {
        // A frame from before the room was recognised: its outline is in the old coordinates.
        guard r.time >= coordinatesMovedAt else { return }
        if case .reject(let d) = r.verdict {
            // A look-alike, or the object taken away faster than the masks show: not drawn there.
            rejected += 1
            Self.append(String(format: "%@\treject\t%d\t%.1f\t%d\t%d\n", Self.now(), id % 1000, d * 1000, r.uncertain ? 1 : 0, r.recentlyLost ? 1 : 0))
            if time - lastRejectLog >= 2 {
                lastRejectLog = time
                log(String(format: "edgetam: mark %d: a mask %.0f mm from where it lay was not taken%@ (%d so far)", id % 1000, d * 1000,
                           r.recentlyLost ? ", just after losing it" : "", rejected))
            }
            if r.uncertain { onLost?(id, true) }
            return
        }
        if r.verdict == .moved {
            log("edgetam: mark \(id % 1000) was moved; its outline follows it to the new place")
            centres = []
            smoothedVelocity = .zero
        }
        if r.frame.present, r.outline.count >= 3, let c = r.world {
            check(id, r, now: c)
            centres.append((r.time, c))
            centres.removeAll { r.time - $0.t > 0.6 }
            let v = velocity()
            follow(r, velocity: v, restart: r.verdict == .moved, time: time)
            onOutline?(id, [r.outline], v, r.time)
        } else {
            let moving = centres.count >= 2 && simd_distance(centres.first!.p, centres.last!.p) > Self.movingDistance
            onLost?(id, moving)
        }
    }

    /// The room's coordinates moved (ARKit recognised the saved room): positions kept from before
    /// are in the old ones, so the gate and the fast tracker start again from the next mask.
    func coordinatesMoved() {
        coordinatesMovedAt = CACurrentMediaTime()
        centres = []
        smoothedVelocity = .zero
        lastDrawn = nil
        lastTaken = nil
        disagreements = 0
        fast.stop()
        worker.resetGate()
    }

    // MARK: Between masks

    /// Keeps the fast tracker on the object EdgeTAM sees: started at the first mask, and again
    /// when it lost the object or moved differently from EdgeTAM between two masks twice in a row.
    private func follow(_ r: EdgeTAMWorker.Tracked, velocity v: simd_float3, restart: Bool, time: TimeInterval) {
        if let d = r.depth { fast.depth = d }
        let centre = Contour.centroid(r.outline)
        if let prev = lastTaken, fast.running, let a = fast.position(at: prev.t), let b = fast.position(at: r.time) {
            let tracked = b - a, seen = centre - prev.p
            if simd_length(tracked - seen) > max(0.015, 0.5 * simd_length(seen)) { disagreements += 1 } else { disagreements = 0 }
        }
        lastTaken = (r.time, centre)
        if restart || !fast.running || disagreements >= 2, time - lastFastStart >= 0.5 {
            fast.start(outline: r.outline, velocity: v, time: r.time)
            lastFastStart = time
            disagreements = 0
        }
    }

    /// How far a steered object moved from its mask's frame (`since`) to the frame shown, as the
    /// fast tracker saw it, and how fast it moves; nil when the tracker cannot be trusted now.
    func liveShift(id: Int, since: TimeInterval, shown: TimeInterval) -> (shift: simd_float3, speed: Float)? {
        guard markID == id, disagreements == 0 else { return nil }
        return fast.shift(since: since, to: shown)
    }

    // MARK: How well the outline holds

    /// The outline drawn since the last mask, against where this mask finds the object: the error
    /// the user saw just before this update (the object's own motion since, plus the depth error
    /// as far as the camera moved). In pixels of the camera image and in millimetres at the
    /// object, like the image lock's check; a summary every three seconds.
    private var lastDrawn: simd_float3?
    private var checks: [(px: Double, mm: Double, moved: Double)] = []
    /// The outline as shown on the mask's own camera frame against the mask: mm, and whether the
    /// object was moving.
    private var shownChecks: [(mm: Double, px: Double, moving: Bool)] = []
    private var lastCheckLog: TimeInterval = 0
    private var rejected = 0
    private var lastRejectLog: TimeInterval = 0

    private func check(_ id: Int, _ r: EdgeTAMWorker.Tracked, now c: simd_float3) {
        defer { lastDrawn = c }
        guard let drawn = lastDrawn, let d = r.depth, let centre = r.frame.centroid else { return }
        let cam = r.camera
        let inCamera = simd_inverse(cam.transform) * simd_float4(drawn, 1)
        guard inCamera.z < -0.05 else { return }
        let k = cam.intrinsics, size = cam.imageResolution
        let z = -inCamera.z
        let drawnPx = CGPoint(x: Double(k[2][0] + k[0][0] * inCamera.x / z), y: Double(k[2][1] - k[1][1] * inCamera.y / z))
        // Upright (u, v) is sensor (v, 1 − u).
        let seenPx = CGPoint(x: centre.y * size.width, y: (1 - centre.x) * size.height)
        let px = hypot(drawnPx.x - seenPx.x, drawnPx.y - seenPx.y)
        let mm = px / Double(k[0][0]) * Double(d) * 1000
        let moved = Double(simd_distance(drawn, c)) * 1000
        checks.append((px, mm, moved))
        // What the user saw on this very frame (the outline with its lead or glide), against
        // where this frame's mask finds the object.
        var shown = "-"
        // Like with like: the drawn outline's centre is the mean of its evenly spaced points, so
        // the mask's outline is compared by the mean of its points too (not by its area's centre).
        if let s = drawnAt?(id, r.time), !r.outline.isEmpty {
            let oc = Contour.centroid(r.outline)
            func pixel(_ w: simd_float3) -> CGPoint? {
                let q = simd_inverse(cam.transform) * simd_float4(w, 1)
                guard q.z < -0.05 else { return nil }
                return CGPoint(x: Double(k[2][0] + k[0][0] * q.x / -q.z), y: Double(k[2][1] - k[1][1] * q.y / -q.z))
            }
            if let sp = pixel(s), let op = pixel(oc) {
                // In the image, as the user sees it, at the drawn outline's distance: a mask's
                // depth can be far off (a small button held 15-40 cm away gave LiDAR 0-1 samples
                // on 1 Nov, and its 3D place was 25 cm out while its outline was right).
                let spx = hypot(sp.x - op.x, sp.y - op.y)
                let camera = simd_float3(cam.transform.columns.3.x, cam.transform.columns.3.y, cam.transform.columns.3.z)
                let smm = spx / Double(k[0][0]) * Double(simd_distance(camera, s)) * 1000
                let moving = moved > 5 || simd_length(smoothedVelocity) >= Self.stillSpeed
                shownChecks.append((smm, spx, moving))
                onShownCheck?(id, smm, moving, r.frame.objectScore >= Self.sureScore)
                shown = String(format: "%.1f\t%.1f\t%d", spx, smm, moving ? 1 : 0)
            }
        }
        Self.append(String(format: "%@\tcheck\t%d\t%.1f\t%.1f\t%.1f\t%.2f\t%@\n", Self.now(), id % 1000, px, mm, moved, d, shown))
        let t = CACurrentMediaTime()
        guard t - lastCheckLog >= 3, !checks.isEmpty else { return }
        lastCheckLog = t
        let mms = checks.map(\.mm).sorted(), moves = checks.map(\.moved).sorted()
        log(String(format: "edgetam check mark %d: outline %.1f mm off (median of %d, max %.1f mm) at %.2f m; object moved %.0f mm per update (max %.0f)",
                   id % 1000, mms[mms.count / 2], mms.count, mms.last!, d, moves[moves.count / 2], moves.last!))
        func summary(_ xs: [Double]) -> String {
            guard !xs.isEmpty else { return "none" }
            let s = xs.sorted()
            return String(format: "median %.1f mm, p90 %.1f, max %.1f (%d)", s[s.count / 2], s[min(s.count - 1, s.count * 9 / 10)], s.last!, s.count)
        }
        if !shownChecks.isEmpty {
            log("edgetam shown mark \(id % 1000): outline on screen vs the object — still: " + summary(shownChecks.filter { !$0.moving }.map(\.mm))
                + "; moving: " + summary(shownChecks.filter(\.moving).map(\.mm)) + "; fast tracker: " + fast.summary)
        }
        checks = []
        shownChecks = []
    }

    /// The object's velocity over the last 0.35 s of masks; below 5 cm/s it counts as still (on
    /// 31 Oct a still object's centre moved 1–2 mm per update, up to 1 cm, from the depth's noise:
    /// that must not push its outline about). An object moved by hand goes 10–50 cm/s.
    static let stillSpeed: Float = 0.05
    private var smoothedVelocity = simd_float3.zero

    private func velocity() -> simd_float3 {
        guard let last = centres.last, let first = centres.first(where: { last.t - $0.t <= 0.35 }), last.t - first.t >= 0.15 else {
            smoothedVelocity = .zero
            return .zero
        }
        let v = (last.p - first.p) / Float(last.t - first.t)
        smoothedVelocity = 0.5 * smoothedVelocity + 0.5 * v
        return simd_length(smoothedVelocity) < Self.stillSpeed ? .zero : smoothedVelocity
    }

    /// Keeps the kept frames of the last few runs only.
    static func pruneRuns() {
        let dir = documents.appendingPathComponent("edgetam")
        let runs = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter(\.hasDirectoryPath).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in runs.dropLast(keepRuns - 1) { try? FileManager.default.removeItem(at: old) }
    }

    /// The mask where the camera image shows it: the 1024² square is the upright image stretched.
    private func draw(_ f: EdgeTAM.Frame, display: CGAffineTransform, viewSize: CGSize) {
        guard f.present, !f.crop.isEmpty, let image = Self.maskImage(f) else {
            maskLayer.contents = nil
            return
        }
        let side = CGFloat(EdgeTAM.side)
        func toView(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            // Upright (u, v) is sensor (v, 1 − u); the display transform takes sensor coordinates.
            let n = CGPoint(x: y / side, y: 1 - x / side).applying(display)
            return CGPoint(x: n.x * viewSize.width, y: n.y * viewSize.height)
        }
        let r = f.cropRect
        let a = toView(r.minX, r.minY), b = toView(r.maxX, r.maxY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.frame = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        maskLayer.contents = image
        CATransaction.commit()
    }

    private static func maskImage(_ f: EdgeTAM.Frame) -> CGImage? {
        let w = Int(f.cropRect.width), h = Int(f.cropRect.height)
        guard w > 0, h > 0, f.crop.count == w * h else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) where f.crop[i] != 0 {
            // Cyan at 45 %, premultiplied.
            rgba[i * 4 + 1] = 115
            rgba[i * 4 + 2] = 115
            rgba[i * 4 + 3] = 115
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    private func status(_ s: String) { onStatus?(s) }
    private func log(_ s: String) { onLog?(s) }

    // MARK: Files

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    static func heat() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "cool"
        case .fair: return "warm"
        case .serious: return "hot"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }

    private static let appendQueue = DispatchQueue(label: "pip.edgetam.log")

    /// Columns: time, mark, prep ms, encode ms, decode ms, total ms, score, predicted IoU, area,
    /// box (x0 y0 x1 y1, upright 0…1), world centre, depth samples, ARKit fps, EdgeTAM fps, heat,
    /// seconds from the frame to its mask, then the decoder's parts: bank, propagator, reading (ms).
    static func append(_ line: String) {
        appendQueue.async {
            let url = documents.appendingPathComponent("edgetam.log")
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    static func write(jpeg image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}

/// EdgeTAM itself, on its own queue: the models are loaded there at the first object, and every
/// frame is prepared, tracked and measured there.
private final class EdgeTAMWorker: @unchecked Sendable {
    struct Request: @unchecked Sendable {
        let buffer: CVPixelBuffer
        let depth: DepthCopy?
        let camera: ARCamera
        let time: TimeInterval
        /// Where to keep this frame and its mask (without extension), or nil.
        let keep: URL?
        /// An image lock saw the object's face recently (see TrackGate).
        let lockHeld: Bool
    }

    struct Seeded: Sendable {
        let frame: EdgeTAM.Frame
        let ms: Double
        let loadSeconds: Double
    }

    struct Tracked: @unchecked Sendable {
        let frame: EdgeTAM.Frame
        let prepMs: Double
        let ms: Double
        let world: simd_float3?
        /// The outline in the room, at the object's depth.
        let outline: [simd_float3]
        let depthSamples: Int
        let time: TimeInterval
        /// The camera of this frame, to measure how far the outline drawn before was off.
        let camera: ARCamera
        let depth: Float?
        /// Whether this mask was taken (see TrackGate); nil when there was nothing to judge.
        let verdict: TrackGate.Verdict?
        /// Masks disagree with where the object lay: its outline waits, hidden.
        let uncertain: Bool
        let recentlyLost: Bool
    }

    enum Failure: Error, CustomStringConvertible {
        case noModels, noInput
        var description: String { self == .noModels ? "models missing (ios/scripts/fetch-edgetam.sh)" : "frame not converted" }
    }

    private let queue = DispatchQueue(label: "pip.edgetam", qos: .userInitiated)
    private var tracker: EdgeTAM?
    /// The object's depth, followed over frames (on the queue): raw LiDAR jitters by millimetres
    /// to a centimetre from frame to frame; a jump of 3 cm is the object moving and is taken at once.
    private var depthFilter: Float?
    private var depthAt: TimeInterval = 0
    static let depthJump: Float = 0.03
    static let minDepthSamples = 5
    /// Keeps the object from jumping to a look-alike (on the queue, with every mask in order).
    private var gate = TrackGate()
    /// When EdgeTAM last did not see the object.
    private var lastAbsent: TimeInterval?
    static let lostFor: TimeInterval = 1.5
    private let input = EdgeTAM.Input()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let keepQueue = DispatchQueue(label: "pip.edgetam.keep", qos: .utility)

    /// The models, once (on the queue).
    private func loaded() throws -> EdgeTAM {
        if let tracker { return tracker }
        guard let folder = Bundle.main.resourceURL,
              FileManager.default.fileExists(atPath: folder.appendingPathComponent(EdgeTAM.names[0] + ".mlmodelc").path) else { throw Failure.noModels }
        let t = try EdgeTAM(compiledIn: folder)
        tracker = t
        return t
    }

    func load(done: @escaping (Result<Double, Error>) -> Void) {
        queue.async { [self] in
            let result = Result<Double, Error> { try loaded().loadSeconds }
            DispatchQueue.main.async { done(result) }
        }
    }

    func seed(image: CGImage, mask: [UInt8], done: @escaping (Result<Seeded, Error>) -> Void) {
        queue.async { [self] in
            let result = Result<Seeded, Error> {
                let tracker = try loaded()
                guard let pixels = input.image(image) else { throw Failure.noInput }
                let t0 = CACurrentMediaTime()
                let f = try tracker.seed(image: pixels, mask: mask)
                depthFilter = nil
                gate.reset()
                lastAbsent = nil
                return Seeded(frame: f, ms: (CACurrentMediaTime() - t0) * 1000, loadSeconds: tracker.loadSeconds)
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    /// Forgets where the object was (new room coordinates); on the queue, in order with the masks.
    func resetGate() {
        queue.async { [self] in
            gate.reset()
            lastAbsent = nil
        }
    }

    func track(_ r: Request, done: @escaping (Result<Tracked, Error>) -> Void) {
        queue.async { [self] in
            let result = Result<Tracked, Error> {
                guard let tracker else { throw Failure.noModels }
                let t0 = CACurrentMediaTime()
                guard let pixels = input.image(r.buffer, orientation: .right) else { throw Failure.noInput }
                let prep = (CACurrentMediaTime() - t0) * 1000
                let f = try tracker.track(image: pixels)
                let (_, samples, measured) = Self.centre(f, depth: r.depth, camera: r.camera)
                let depthBefore = depthFilter
                // A depth needs a few LiDAR samples on the object (closer than about 25 cm, or on
                // a small dark button, there are none or one, and one can be the floor behind it);
                // without them the last good depth holds for a second, then there is no 3D place.
                let rawDepth = samples >= Self.minDepthSamples ? measured : nil
                var depth = rawDepth.map { d -> Float in
                    let smooth = depthFilter.map { abs(d - $0) > Self.depthJump ? d : $0 + 0.35 * (d - $0) } ?? d
                    depthFilter = smooth
                    depthAt = r.time
                    return smooth
                }
                if depth == nil, let held = depthFilter, r.time - depthAt < 1 { depth = held }
                let world = depth.flatMap { d in f.centroid.map { Self.lift([$0], depth: d, camera: r.camera)[0] } }
                let outline = depth.map { Self.lift(f.outline, depth: $0, camera: r.camera) } ?? []
                // A mask on a look-alike is neither shown nor remembered: EdgeTAM forgets the frame
                // at once, before the next one, so it keeps looking for the right object.
                let recentlyLost = lastAbsent.map { r.time - $0 < Self.lostFor } ?? false
                var verdict: TrackGate.Verdict?
                if f.present, let w = world {
                    verdict = gate.judge(time: r.time, position: w, area: Float(f.area), lockHeld: r.lockHeld, recentlyLost: recentlyLost)
                    if case .reject = verdict {
                        tracker.forgetLatest()
                        depthFilter = depthBefore
                    }
                } else if !f.present {
                    lastAbsent = r.time
                }
                let ms = (CACurrentMediaTime() - t0) * 1000
                // Kept frames are written on the side, so they never hold up the next frame.
                if let keep = r.keep {
                    let buffer = r.buffer
                    self.keepQueue.async { self.keep(buffer, f, world: world, at: keep) }
                }
                return Tracked(frame: f, prepMs: prep, ms: ms, world: world, outline: outline, depthSamples: samples, time: r.time,
                               camera: r.camera, depth: depth, verdict: verdict, uncertain: gate.uncertain, recentlyLost: recentlyLost)
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    /// The object's centre in the room: the mask's centre at the median raw LiDAR depth inside the
    /// mask (raw, not smoothed: smoothing lags a moving object).
    static func centre(_ f: EdgeTAM.Frame, depth: DepthCopy?, camera: ARCamera) -> (simd_float3?, Int, Float?) {
        guard f.present, let c = f.centroid, let depth else { return (nil, 0, nil) }
        var samples: [Float] = []
        for dy in 0..<depth.height {
            for dx in 0..<depth.width {
                // Sensor (u, v) is upright (1 − v, u).
                let us = (Double(dx) + 0.5) / Double(depth.width), vs = (Double(dy) + 0.5) / Double(depth.height)
                guard f.contains(u: 1 - vs, v: us) else { continue }
                let i = dy * depth.width + dx
                if let conf = depth.confidence, conf[i] < 1 { continue }
                let d = depth.values[i]
                if d.isFinite, d > 0.05 { samples.append(d) }
            }
        }
        guard !samples.isEmpty else { return (nil, 0, nil) }
        samples.sort()
        let d = samples[samples.count / 2]
        let size = camera.imageResolution
        // Upright (u, v) is sensor (v, 1 − u).
        let px = Float(c.y) * Float(size.width), py = Float(1 - c.x) * Float(size.height)
        let k = camera.intrinsics
        let x = (px - k[2][0]) / k[0][0] * d, y = -(py - k[2][1]) / k[1][1] * d
        let p = camera.transform * simd_float4(x, y, -d, 1)
        return (simd_float3(p.x, p.y, p.z), samples.count, d)
    }

    /// Normalised upright points (the mask's outline) on their camera rays at depth `d`, in the
    /// room: the object taken as facing the camera. Over the 0.1 s until the next mask, a depth
    /// error only shows as far as the camera moves meanwhile.
    static func lift(_ points: [CGPoint], depth d: Float, camera: ARCamera) -> [simd_float3] {
        let size = camera.imageResolution, k = camera.intrinsics, t = camera.transform
        return points.map { p in
            // Upright (u, v) is sensor (v, 1 − u).
            let px = Float(p.y) * Float(size.width), py = Float(1 - p.x) * Float(size.height)
            let x = (px - k[2][0]) / k[0][0] * d, y = -(py - k[2][1]) / k[1][1] * d
            let w = t * simd_float4(x, y, -d, 1)
            return simd_float3(w.x, w.y, w.z)
        }
    }

    /// The upright frame (720×960 JPEG), the full-resolution mask around the object (PNG, pixels of
    /// the 1024² square) and the numbers, for comparing with SAM 3.1 on the Mac.
    private func keep(_ buffer: CVPixelBuffer, _ f: EdgeTAM.Frame, world: simd_float3?, at base: URL) {
        let upright = CIImage(cvPixelBuffer: buffer).oriented(.right)
        let e = upright.extent
        let scaled = upright.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(CGAffineTransform(scaleX: 720 / e.width, y: 960 / e.height)))
        if let cg = context.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: 720, height: 960)) {
            EdgeTAMSpike.write(jpeg: cg, to: base.appendingPathExtension("jpg"))
        }
        let w = Int(f.cropRect.width), h = Int(f.cropRect.height)
        if w > 0, h > 0, f.crop.count == w * h, let provider = CGDataProvider(data: Data(f.crop.map { $0 * 255 }) as CFData),
           let mask = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
           let dest = CGImageDestinationCreateWithURL(base.appendingPathExtension("png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, mask, nil)
            CGImageDestinationFinalize(dest)
        }
        let meta: [String: Any] = [
            "score": f.objectScore, "iou": f.iou, "area": f.area,
            "crop": [f.cropRect.minX, f.cropRect.minY, f.cropRect.width, f.cropRect.height],
            "box": f.box.map { [$0.minX, $0.minY, $0.maxX, $0.maxY] } ?? [],
            "world": world.map { [$0.x, $0.y, $0.z] } ?? [],
        ]
        try? JSONSerialization.data(withJSONObject: meta).write(to: base.appendingPathExtension("json"))
    }
}
