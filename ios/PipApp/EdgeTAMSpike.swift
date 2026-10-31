import ARKit
import CoreImage
import ImageIO
import PipCore
import UIKit
import UniformTypeIdentifiers

/// Spike T1 (docs/research-precision.md): Meta's EdgeTAM follows the latest pointed-at object live
/// on the Neural Engine, next to Pip's own outline, drawn as a cyan mask. It measures what decides
/// whether it can carry the object tier: the time per frame with ARKit running, ARKit's own frame
/// rate, the phone's heat, and the mask itself. Per frame a line in Documents/edgetam.log; every
/// second a frame with its mask in Documents/edgetam/<start>/, to compare with SAM 3.1 on the Mac.
/// One object at a time, for at most two minutes.
final class EdgeTAMSpike {
    static let enabledKey = "pip.edgetamSpike"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static let followFor: TimeInterval = 120
    static let keepEvery: TimeInterval = 1
    static let maxKept = 90

    /// Over the camera image, under Pip's own outlines.
    let view = UIView()
    private let maskLayer = CALayer()
    var onStatus: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    private let worker = EdgeTAMWorker()
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
        guard seeded, !busy, viewSize.width > 0 else { return }
        busy = true
        let me = run
        let keep = kept < Self.maxKept && t - lastKept >= Self.keepEvery
        if keep { lastKept = t; kept += 1 }
        let index = kept
        let request = EdgeTAMWorker.Request(buffer: frame.capturedImage, depth: DepthCopy(frame.sceneDepth), camera: frame.camera, time: t,
                                            keep: keep ? folder?.appendingPathComponent(String(format: "%03d", index)) : nil)
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
            self.draw(r.frame, display: display, viewSize: viewSize)
            let recent = self.doneTimes.filter { done - $0 <= 1 }.count
            let f = r.frame
            let b = f.box ?? .zero
            Self.append(String(format: "%@\t%d\t%.1f\t%.1f\t%.1f\t%.1f\t%.2f\t%.3f\t%.5f\t%.4f\t%.4f\t%.4f\t%.4f\t%@\t%d\t%d\t%d\t%@\t%.3f\n",
                               Self.now(), id % 1000, r.prepMs, f.encodeMs, f.decodeMs, r.ms, f.objectScore, f.iou, f.area,
                               b.minX, b.minY, b.maxX, b.maxY,
                               r.world.map { String(format: "%.4f,%.4f,%.4f", $0.x, $0.y, $0.z) } ?? "-", r.depthSamples, arFps, recent,
                               // ARKit's frame times run on the same clock as CACurrentMediaTime.
                               Self.heat(), done - r.time))
            if done - self.lastStatus > 0.25 {
                self.lastStatus = done
                self.status(String(format: "EdgeTAM %d fps · %.0f ms · score %.1f · AR %d fps · %@", recent, r.ms, f.objectScore, arFps, Self.heat()))
            }
        }
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
    /// seconds from the frame to its mask.
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
        let depthSamples: Int
        let time: TimeInterval
    }

    enum Failure: Error, CustomStringConvertible {
        case noModels, noInput
        var description: String { self == .noModels ? "models missing (ios/scripts/fetch-edgetam.sh)" : "frame not converted" }
    }

    private let queue = DispatchQueue(label: "pip.edgetam", qos: .userInitiated)
    private var tracker: EdgeTAM?
    private let input = EdgeTAM.Input()
    private let context = CIContext(options: [.cacheIntermediates: false])

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
                return Seeded(frame: f, ms: (CACurrentMediaTime() - t0) * 1000, loadSeconds: tracker.loadSeconds)
            }
            DispatchQueue.main.async { done(result) }
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
                let (world, samples) = Self.centre(f, depth: r.depth, camera: r.camera)
                let ms = (CACurrentMediaTime() - t0) * 1000
                if let keep = r.keep { self.keep(r.buffer, f, world: world, at: keep) }
                return Tracked(frame: f, prepMs: prep, ms: ms, world: world, depthSamples: samples, time: r.time)
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    /// The object's centre in the room: the mask's centre at the median raw LiDAR depth inside the
    /// mask (raw, not smoothed: smoothing lags a moving object).
    static func centre(_ f: EdgeTAM.Frame, depth: DepthCopy?, camera: ARCamera) -> (simd_float3?, Int) {
        guard f.present, let c = f.centroid, let depth else { return (nil, 0) }
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
        guard !samples.isEmpty else { return (nil, 0) }
        samples.sort()
        let d = samples[samples.count / 2]
        let size = camera.imageResolution
        // Upright (u, v) is sensor (v, 1 − u).
        let px = Float(c.y) * Float(size.width), py = Float(1 - c.x) * Float(size.height)
        let k = camera.intrinsics
        let x = (px - k[2][0]) / k[0][0] * d, y = -(py - k[2][1]) / k[1][1] * d
        let p = camera.transform * simd_float4(x, y, -d, 1)
        return (simd_float3(p.x, p.y, p.z), samples.count)
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
