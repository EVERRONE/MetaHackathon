import ARKit
import CoreGraphics
import PipCore
import QuartzCore
import simd

/// Keeps the outlines of pointed-at objects on them in the camera image, every frame, whatever the
/// object or the phone does (PlanarTracker: corners on the object followed from frame to frame,
/// a homography from its first view to now, aligned against that first view so nothing drifts).
/// The keys on one keyboard share its tracker, so they move, turn and tilt together and never
/// jump to a neighbouring key. Each outline is also laid into the room at its depth, for the
/// arrow when it is out of view.
///
/// An object lost while it lay still (out of view, a hand over it) keeps its place in the room and
/// is looked for there again; one lost while it moved is hidden until it is found again. This
/// replaces the ARKit image locks, the box follower and riding along with EdgeTAM (2 Nov: the
/// image locks were a key or two off on a keyboard, and the hand-overs between them lost keys).
final class PlanarFollower {
    /// Tracking size: upright, half the camera's 1440×1920.
    static let width = 720, height = 960
    /// Lost while it seemed still and not found where it lay, that place in view, for this long:
    /// taken as moved, and hidden until found (a hand over it, or blur, mostly passes sooner: on
    /// 2 Nov 26 of 30 finds where it lay came within half a second; a later one shows it again).
    static let notWhereItLayAfter: TimeInterval = 0.7

    private struct Object {
        var tracker: PlanarTracker
        /// The marks on it, their outlines in reference pixels.
        var targets: [Int: [[CGPoint]]]
        /// Each mark's distance from the camera, smoothed (metres).
        var depth: [Int: Float]
        /// The region's corners in the reference, and in the room when last seen (to look for it
        /// again where it was).
        var corners: [CGPoint]
        var cornersWorld: [simd_float3]
        var lostSince: TimeInterval?
        var lostMoving = false
        /// Lost while it seemed still, and not found where it lay although that place was in view:
        /// it was moved after all (for the log).
        var notWhereItLay = false
        var lastTry: TimeInterval = 0
        /// The reference is still the snapshot (a live frame takes over once it is followed well).
        var onSnapshot = true
        /// How it was last found again: where it was, or anywhere by its corners.
        var foundBy = ""
        /// When its described corners last confirmed it (the watch against look-alikes).
        var lastCheck: TimeInterval = 0
        /// A look-alike was caught (the watch), for the log.
        var slid = false
        /// Recent centres in the room, to tell a moving object from a still one when it is lost
        /// (in the image the phone's own motion would count too).
        var recent: [(t: TimeInterval, p: simd_float3)] = []
    }

    private var objects: [Int: Object] = [:]
    private let queue = DispatchQueue(label: "pip.planar", qos: .userInteractive)
    private var busy = false

    /// A mark's outline in the room, from the frame of `time` (main thread).
    var onOutline: ((Int, [[simd_float3]], TimeInterval) -> Void)?
    /// Marks whose object was lost; `moving`: it moved just before (then they are hidden).
    var onLost: (([Int], Bool) -> Void)?
    var onLog: ((String) -> Void)?

    var isEmpty: Bool { objects.isEmpty }

    /// Starts following an object from the snapshot its marks were measured on: `region` its
    /// outline there (snapshot pixels), `targets` the marks on it (snapshot pixels), `surface` lays a
    /// snapshot point on the object's surface in the room (to find it in the current frame).
    func follow(_ targets: [Int: [[CGPoint]]], region: [CGPoint], snapshot: FrameSnapshot, surface: (CGPoint) -> simd_float3?, frame: ARFrame) {
        guard let reference = GrayImage(snapshot.image)?.resized(width: Self.width, height: Self.height) else { return }
        let s = CGFloat(Self.width) / CGFloat(snapshot.image.width)
        let outline = region.map { CGPoint(x: $0.x * s, y: $0.y * s) }
        var tracker = PlanarTracker()
        guard tracker.start(image: reference, outline: outline) else {
            onLog?("follow: too little texture on marks \(Self.label(targets.keys)) to follow in the image")
            return
        }
        // The region's box corners on the object's surface in the room: where they are in this frame.
        let box = region.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let snapCorners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        let world = snapCorners.compactMap(surface)
        guard world.count == 4 else { return }
        let corners = snapCorners.map { CGPoint(x: $0.x * s, y: $0.y * s) }
        var object = Object(tracker: tracker, targets: targets.mapValues { rings in rings.map { ring in ring.map { CGPoint(x: $0.x * s, y: $0.y * s) } } },
                            depth: [:], corners: corners, cornersWorld: world)
        let group = targets.keys.min() ?? 0
        // On to the current frame: predicted from the camera's motion and aligned against the
        // snapshot; if it moved meanwhile, found again by its described corners.
        guard let image = Self.gray(frame) else { return }
        // Checked by its described corners: the prediction from the camera's motion can be a key or
        // two off (a few millimetres of the room's coordinates, more right after tracking started
        // afresh), and aligned from there it settles on the look-alike (1 Nov).
        let predicted = Self.predict(object, camera: frame.camera)
        guard let found = object.tracker.reacquire(in: image, predicted: predicted) else {
            object.lostSince = CACurrentMediaTime()
            objects[group] = object
            onLog?("follow: marks \(Self.label(targets.keys)) not found in the live image yet; looked for again")
            return
        }
        let how = found == .byCorners ? "found by its corners" : "from the camera's motion"
        object.lastCheck = CACurrentMediaTime()
        Self.rebase(&object, on: image, checked: true)
        objects[group] = object
        onLog?("follow: marks \(Self.label(targets.keys)) followed in the image (\(object.tracker.inliers) points, \(how))")
    }

    func stop(_ ids: Set<Int>) {
        for (group, var object) in objects {
            object.targets = object.targets.filter { !ids.contains($0.key) }
            objects[group] = object.targets.isEmpty ? nil : object
        }
    }

    /// Every camera frame: the objects are followed on a queue of their own, a frame at a time.
    func frame(_ frame: ARFrame) {
        guard !objects.isEmpty, !busy else { return }
        busy = true
        let objects = self.objects
        let camera = frame.camera, buffer = frame.capturedImage, depth = frame.sceneDepth?.depthMap, time = frame.timestamp
        queue.async { [weak self] in
            var results: [(group: Int, object: Object, outlines: [Int: [[simd_float3]]], lost: [Int]?, found: String?, time: TimeInterval)] = []
            if let image = Self.gray(buffer) {
                for (group, var object) in objects {
                    let away = object.lostSince.map { CACurrentMediaTime() - $0 }
                    let (outlines, lost) = Self.step(&object, image: image, camera: camera, depth: depth, time: time)
                    let found = away != nil && object.lostSince == nil ? String(format: "%@ after %.1f s", object.foundBy, away!) : nil
                    results.append((group, object, outlines, lost, found, time))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                for r in results {
                    // Marks stopped meanwhile are not brought back.
                    guard let live = self.objects[r.group] else { continue }
                    var object = r.object
                    object.targets = object.targets.filter { live.targets[$0.key] != nil }
                    if object.slid {
                        object.slid = false
                        self.onLog?("follow: marks \(Self.label(live.targets.keys)) were on a look-alike; put back where their corners are")
                    }
                    self.objects[r.group] = object.targets.isEmpty ? nil : object
                    for (id, rings) in r.outlines where live.targets[id] != nil { self.onOutline?(id, rings, r.time) }
                    if let found = r.found { self.onLog?("follow: marks \(Self.label(live.targets.keys)) found again \(found)") }
                    if let lost = r.lost {
                        self.onLost?(lost.filter { live.targets[$0] != nil }, object.lostMoving)
                        let why = object.notWhereItLay ? " not where they lay: hidden until found again"
                            : (object.lostMoving ? " lost while moving: hidden until found again" : " lost; kept where they lay, dotted, looked for there")
                        self.onLog?("follow: marks \(Self.label(lost))\(why)")
                    }
                }
            }
        }
    }

    /// One frame for one object: its marks' outlines in the room, and the marks just lost.
    private static func step(_ object: inout Object, image: GrayImage, camera: ARCamera, depth: CVPixelBuffer?, time: TimeInterval) -> ([Int: [[simd_float3]]], [Int]?) {
        let now = CACurrentMediaTime()
        if let since = object.lostSince {
            let predicted = predict(object, camera: camera)
            // Lost while it seemed still, and not found where it lay while that place is in view: it
            // was moved, slowly enough that the last 0.3 s did not show it. Its outlines are hidden
            // rather than left on whatever lies there now (2 Nov: a laptop pushed across the desk;
            // its key rings stayed on the touchpad for 26 s).
            var hideNow = false
            if !object.lostMoving, predicted != nil, now - since > notWhereItLayAfter {
                object.lostMoving = true
                object.notWhereItLay = true
                hideNow = true
            }
            let lostAgain: [Int]? = hideNow ? Array(object.targets.keys) : nil
            // Looked for again a few times a second, where it was (cheap) and anywhere in the frame by
            // its described corners (moved far, turned). With its place out of view, once a second
            // anywhere: it may have been moved into view (2 Nov: found again only after 26 to 113 s,
            // when the phone came back to where it had lain).
            guard now - object.lastTry > (predicted != nil || object.lostMoving ? 0.2 : 1.0) else { return ([:], lostAgain) }
            object.lastTry = now
            // Checked by its described corners (never a look-alike); without them (blur) only right
            // after a brief loss of an object that lay still, where it was predicted.
            let brief = now - since < 0.5 && !object.lostMoving
            guard let found = object.tracker.reacquire(in: image, predicted: predicted, trustPrediction: brief) else { return ([:], lostAgain) }
            object.foundBy = found == .byCorners ? "by its corners" : "where it was"
            object.lostSince = nil
            object.notWhereItLay = false
            object.recent = []
            object.lastCheck = now
            if object.onSnapshot { rebase(&object, on: image, checked: found != .wherePredictedUnchecked) }
        } else if object.tracker.track(image) == .lost {
            object.lostSince = now
            let moved = object.recent.count >= 2 ? simd_distance(object.recent.last!.p, object.recent.first!.p) : 0
            object.lostMoving = moved > 0.02
            return ([:], Array(object.targets.keys))
        }
        // The watch: once a second the described corners must agree with where it is followed; a
        // look-alike taken meanwhile (a fast jolt along a row of keys) is left for where they are.
        if now - object.lastCheck > 1.0 {
            object.lastCheck = now
            if let check = object.tracker.confirmed(in: image) {
                if !check.agrees {
                    var moved = object.tracker
                    if moved.relocate(to: image, predicted: check.fit) == .tracking {
                        object.tracker = moved
                        object.slid = true
                    }
                }
                if object.onSnapshot { rebase(&object, on: image, checked: true) }
            }
        }
        let h = object.tracker.homography
        var outlines: [Int: [[simd_float3]]] = [:]
        var depths: [Float] = []
        for (id, rings) in object.targets {
            let shown = rings.map { ring in ring.map { h.apply($0) } }
            let all = shown.flatMap { $0 }
            guard !all.isEmpty else { continue }
            let centre = CGPoint(x: all.map(\.x).reduce(0, +) / CGFloat(all.count), y: all.map(\.y).reduce(0, +) / CGFloat(all.count))
            if let d = sampleDepth(depth, at: centre) {
                object.depth[id] = object.depth[id].map { 0.7 * $0 + 0.3 * d } ?? d
            }
            guard let d = object.depth[id] ?? depthOfCorners(object, camera: camera) else { continue }
            depths.append(d)
            outlines[id] = shown.map { ring in ring.map { lift($0, depth: d, camera: camera) } }
        }
        // The region's corners in the room, at the marks' depth: where to look for it if it is lost.
        if let d = depths.isEmpty ? nil : depths.reduce(0, +) / Float(depths.count) {
            object.cornersWorld = object.corners.map { lift(h.apply($0), depth: d, camera: camera) }
        }
        object.recent.append((time, object.cornersWorld.reduce(.zero, +) / Float(object.cornersWorld.count)))
        object.recent.removeAll { time - $0.t > 0.3 }
        return (outlines, nil)
    }

    /// A live frame becomes the reference once the object is followed well in it (sharp, many
    /// points): the snapshot was converted to grey otherwise than camera frames are. The marks and
    /// corners are mapped onto it.
    /// `checked`: its described corners agreed on this frame; a look-alike taken up as the reference
    /// would stay (1 Nov: the snapshot was left for a frame two keys off, then followed there).
    private static func rebase(_ object: inout Object, on image: GrayImage, checked: Bool) {
        guard checked, object.onSnapshot, object.tracker.residual < 0.8, let h = object.tracker.rebase(on: image) else { return }
        object.targets = object.targets.mapValues { rings in rings.map { ring in ring.map { h.apply($0) } } }
        object.corners = object.corners.map { h.apply($0) }
        object.onSnapshot = false
    }

    /// Reference → this frame, from where the region's corners are in the room (the object as it
    /// was: still, or last seen).
    private static func predict(_ object: Object, camera: ARCamera) -> simd_float3x3? {
        let size = CGSize(width: width, height: height)
        let projected = object.cornersWorld.map { camera.projectPoint($0, orientation: .portrait, viewportSize: size) }
        // In front of the camera, and on or near the frame.
        let inFront = object.cornersWorld.allSatisfy { (simd_inverse(camera.transform) * simd_float4($0, 1)).z < -0.05 }
        guard inFront, projected.contains(where: { CGRect(origin: .zero, size: size).insetBy(dx: -100, dy: -100).contains($0) }) else { return nil }
        return PlanarTracker.homography(from: object.corners, to: projected)
    }

    private static func depthOfCorners(_ object: Object, camera: ARCamera) -> Float? {
        let zs = object.cornersWorld.map { -(simd_inverse(camera.transform) * simd_float4($0, 1)).z }
        return zs.isEmpty ? nil : zs.reduce(0, +) / Float(zs.count)
    }

    /// An upright tracking pixel at camera-space depth `d`, in the room.
    private static func lift(_ p: CGPoint, depth d: Float, camera: ARCamera) -> simd_float3 {
        let res = camera.imageResolution, k = camera.intrinsics
        // Upright (u, v) is sensor (v, 1 − u), normalised.
        let sx = Float(p.y) / Float(height) * Float(res.width), sy = (1 - Float(p.x) / Float(width)) * Float(res.height)
        let x = (sx - k[2][0]) / k[0][0] * d, y = -(sy - k[2][1]) / k[1][1] * d
        return (camera.transform * simd_float4(x, y, -d, 1)).xyz
    }

    /// LiDAR depth at an upright tracking pixel (the median of a few samples around it).
    private static func sampleDepth(_ buffer: CVPixelBuffer?, at p: CGPoint) -> Float? {
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        let cx = Int(Float(p.y) / Float(height) * Float(w)), cy = Int((1 - Float(p.x) / Float(width)) * Float(h))
        var values: [Float] = []
        for dy in -1...1 {
            for dx in -1...1 {
                let x = cx + dx, y = cy + dy
                guard x >= 0, y >= 0, x < w, y < h else { continue }
                let v = (base + y * row).assumingMemoryBound(to: Float32.self)[x]
                if v.isFinite, v > 0.1 { values.append(v) }
            }
        }
        guard values.count >= 3 else { return nil }
        return values.sorted()[values.count / 2]
    }

    /// The camera image as upright grey at the tracking size (each pixel the mean of 2×2).
    static func gray(_ frame: ARFrame) -> GrayImage? { gray(frame.capturedImage) }

    static func gray(_ buffer: CVPixelBuffer) -> GrayImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) >= 1, let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let sw = CVPixelBufferGetWidthOfPlane(buffer, 0), sh = CVPixelBufferGetHeightOfPlane(buffer, 0), row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard sw >= 2 * height, sh >= 2 * width else { return nil }
        let src = base.assumingMemoryBound(to: UInt8.self)
        var px = [Float](repeating: 0, count: width * height)
        // Upright (u, v) ← sensor (2v, sh − 2 − 2u): a quarter turn clockwise, halved.
        px.withUnsafeMutableBufferPointer { out in
            for v in 0..<height {
                let sx = 2 * v
                for u in 0..<width {
                    let sy = sh - 2 - 2 * u
                    let i = sy * row + sx
                    let sum = Int(src[i]) + Int(src[i + 1]) + Int(src[i + row]) + Int(src[i + row + 1])
                    out[v * width + u] = Float(sum) * 0.25
                }
            }
        }
        return GrayImage(width: width, height: height, pixels: px)
    }

    static func label<S: Sequence>(_ ids: S) -> String where S.Element == Int { ids.sorted().map { String($0 % 1000) }.joined(separator: ",") }
}
