import ARKit
import CoreImage
import Vision
import simd

/// Follows pointed-at objects in the camera image, about 20 times a second, on the iPhone.
///
/// Outlines are anchored in the room, which is the steadiest for things that stay put. But a
/// remote in the hand moves: between the user's question and the answer (a few seconds) and while
/// they hold it. So each pointed-at object is also followed in the image (Apple Vision's object
/// tracker). When the object is where its room anchor says, nothing changes. When it has moved,
/// the outline follows the object on screen; once it lies still again, Pip measures it anew and
/// anchors it at its new place (`onSettled`). If the tracker loses a moving object, its outline is
/// hidden rather than left floating where the object was. Used on the main thread (with the AR
/// session's frames); the tracking itself runs on a background queue.
final class ImageFollower {
    /// How a mark is drawn on screen this frame: its projected centre moved to where the object is.
    struct Adjust {
        var from: CGPoint
        var to: CGPoint
        var scale: CGFloat
        var hidden = false
    }

    private struct Follow {
        var box: CGRect?          // sensor-normalised, Vision's (bottom-left) convention
        var movingFrames = 0
        var moving = false
        var lostFrames = 0
        var lastCentre: CGPoint?
        var stillSince: TimeInterval?
    }

    /// Marks to start following: the snapshot they were measured in and their box there.
    private var pending: [Int: (image: CGImage, box: CGRect)] = [:]
    /// The same, kept while a mark is followed: an object that lay still and was lost (a hand over
    /// it) is looked for again with it, until it is found.
    private var templates: [Int: (image: CGImage, box: CGRect)] = [:]
    /// When to look again for a lost object that lay still.
    private var retryAt: [Int: TimeInterval] = [:]
    static let retryInterval: TimeInterval = 0.5
    private var follows: [Int: Follow] = [:]
    private let worker = Worker()
    private var busy = false
    private var lastRun: TimeInterval = 0
    private(set) var adjust: [Int: Adjust] = [:]

    /// A moved object has lain still for a moment: measure it again (its box in screen points).
    var onSettled: ((Int, CGRect) -> Void)?
    var onLog: ((String) -> Void)?

    static let rate: TimeInterval = 1.0 / 20
    static let maxFollowed = 3

    /// A mark was just placed from `image` (the frame the user asked about), `box` in its pixels.
    func start(_ id: Int, image: CGImage, box: CGRect) {
        pending[id] = (image, box)
        templates[id] = (image, box)
        retryAt[id] = nil
        follows[id] = nil
        adjust[id] = nil
    }

    func stop(_ id: Int) {
        pending[id] = nil
        templates[id] = nil
        retryAt[id] = nil
        follows[id] = nil
        adjust[id] = nil
        worker.drop(id)
    }

    /// A fresh 3D measurement put the mark where the object is: following starts again from it.
    func reanchored(_ id: Int) {
        guard var f = follows[id] else { return }
        f.moving = false
        f.movingFrames = 0
        f.stillSince = nil
        follows[id] = f
        adjust[id] = nil
    }

    /// Called for camera frames with the marks that have a cue on screen and their projected box
    /// (screen points). `view` converts between the camera image and the screen.
    func update(frame: ARFrame, shown: [(id: Int, box: CGRect)], viewSize: CGSize) {
        let t = frame.timestamp
        guard !busy, t - lastRun >= Self.rate, viewSize.width > 0 else { return }
        let ids = Set(shown.map(\.id))
        // Off screen (or its cue gone for now): not followed meanwhile, but its template stays, so it
        // is looked for again, strictly, where it is once it is back in view (1 Nov review: a mark
        // that left the view was never followed again, and keys picked up after a look round kept
        // their outline behind). `stop` forgets it when its mark goes.
        for id in Set(follows.keys).union(retryAt.keys) where !ids.contains(id) && pending[id] == nil {
            if follows.removeValue(forKey: id) != nil { worker.drop(id) }
            adjust[id] = nil
            if templates[id] != nil, retryAt[id] == nil { retryAt[id] = t }
        }
        let wanted = shown.prefix(Self.maxFollowed)
        guard !wanted.isEmpty else { return }
        lastRun = t
        busy = true
        let toImage = frame.displayTransform(for: .portrait, viewportSize: viewSize).inverted()
        let toScreen = frame.displayTransform(for: .portrait, viewportSize: viewSize)
        // Starts: the snapshot's object looked for in this frame near where its anchor projects.
        // A lost object is only taken up again where it is really found, never on what covered it.
        var starts: [(id: Int, image: CGImage, box: CGRect, predicted: CGRect, strict: Bool)] = []
        for (id, box) in wanted {
            let predicted = Self.visionRect(screen: box, viewSize: viewSize, toImage: toImage)
            if let p = pending.removeValue(forKey: id) {
                starts.append((id, p.image, p.box, predicted, false))
            } else if let due = retryAt[id], t >= due, let p = templates[id] {
                retryAt[id] = t + Self.retryInterval
                starts.append((id, p.image, p.box, predicted, true))
            }
        }
        let tracked = wanted.map(\.id).filter { follows[$0] != nil }
        let buffer = frame.capturedImage
        let worker = worker
        let shownNow = Array(wanted)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [Int: CGRect] = [:]
            for s in starts {
                found[s.id] = worker.reacquire(id: s.id, template: s.image, box: s.box, predicted: s.predicted, strict: s.strict, in: buffer)
            }
            let results = worker.track(tracked, in: buffer)
            DispatchQueue.main.async {
                self?.apply(found: found, results: results, shown: shownNow, toScreen: toScreen, viewSize: viewSize, time: t)
            }
        }
    }

    private func apply(found: [Int: CGRect], results: [Int: (CGRect, Float)], shown: [(id: Int, box: CGRect)], toScreen: CGAffineTransform, viewSize: CGSize, time t: TimeInterval) {
        busy = false
        for (id, box) in found where templates[id] != nil {
            follows[id] = Follow(box: box)
            onLog?(retryAt.removeValue(forKey: id) != nil ? "follow: mark \(id % 1000) found again" : "follow: mark \(id % 1000) found in the live image")
        }
        for (id, projected) in shown {
            guard var f = follows[id] else { continue }
            if let (box, confidence) = results[id] {
                f.box = box
                f.lostFrames = confidence < 0.3 ? f.lostFrames + 1 : 0
            } else {
                // Vision gave nothing for it this frame: its old box is no sighting.
                f.lostFrames += 1
            }
            guard let box = f.box, f.lostFrames < 5 else {
                // Lost. A moving object's outline is hidden rather than left behind. One that lay
                // still keeps its room anchor and is looked for again (see `templates`).
                adjust[id] = f.moving ? Adjust(from: .zero, to: .zero, scale: 1, hidden: true) : nil
                follows[id] = f.moving ? f : nil
                if !f.moving {
                    worker.drop(id)
                    retryAt[id] = t + Self.retryInterval
                }
                continue
            }
            let screen = Self.screenRect(vision: box, viewSize: viewSize, toScreen: toScreen)
            let off = hypot(screen.midX - projected.midX, screen.midY - projected.midY)
            let size = max(projected.width, projected.height, 20)
            if off > max(14, 0.3 * size) { f.movingFrames = min(f.movingFrames + 1, 10) } else { f.movingFrames = max(f.movingFrames - 1, 0) }
            if !f.moving, f.movingFrames >= 3 {
                f.moving = true
                onLog?("follow: mark \(id % 1000) is moving; the outline follows it")
            }
            if f.moving {
                let scale = max(0.5, min(2, max(screen.width, screen.height) / max(1, max(projected.width, projected.height))))
                adjust[id] = Adjust(from: CGPoint(x: projected.midX, y: projected.midY), to: CGPoint(x: screen.midX, y: screen.midY), scale: scale)
                // Still for 0.8 s at its new place: time to measure it again in 3D.
                let centre = CGPoint(x: screen.midX, y: screen.midY)
                if let last = f.lastCentre, hypot(centre.x - last.x, centre.y - last.y) < 4 {
                    if let since = f.stillSince, t - since > 0.8 {
                        f.stillSince = nil
                        onSettled?(id, screen)
                    } else if f.stillSince == nil {
                        f.stillSince = t
                    }
                } else {
                    f.stillSince = nil
                }
                f.lastCentre = centre
            } else {
                adjust[id] = nil
            }
            follows[id] = f
        }
    }

    // MARK: Coordinates

    /// Screen points → Vision's normalised rect in the captured (sensor) image, origin bottom-left.
    nonisolated static func visionRect(screen r: CGRect, viewSize: CGSize, toImage: CGAffineTransform) -> CGRect {
        let n = CGRect(x: r.minX / viewSize.width, y: r.minY / viewSize.height, width: r.width / viewSize.width, height: r.height / viewSize.height)
        let img = n.applying(toImage).standardized
        return CGRect(x: img.minX, y: 1 - img.maxY, width: img.width, height: img.height)
    }

    nonisolated static func screenRect(vision r: CGRect, viewSize: CGSize, toScreen: CGAffineTransform) -> CGRect {
        let img = CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
        let n = img.applying(toScreen).standardized
        return CGRect(x: n.minX * viewSize.width, y: n.minY * viewSize.height, width: n.width * viewSize.width, height: n.height * viewSize.height)
    }
}

/// The tracking itself, on its own thread: Vision's object tracker per mark, and finding a
/// snapshot's object again in a live frame (normalised cross-correlation of the grey images).
private final class Worker: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [Int: VNTrackObjectRequest] = [:]
    /// Trackers to release: Vision frees a tracker only after a last frame with `isLastFrame`,
    /// and refuses new ones once too many are held.
    private var finishing: [VNTrackObjectRequest] = []
    private let handler = VNSequenceRequestHandler()

    func drop(_ id: Int) {
        lock.lock()
        if let r = requests.removeValue(forKey: id) { finish(r) }
        lock.unlock()
    }

    /// Call with the lock held. `isLastFrame` is set in `track`, on the tracking thread, never
    /// while Vision may be running the request.
    private func finish(_ request: VNTrackObjectRequest) {
        finishing.append(request)
    }

    /// The object of `box` (pixels of the upright snapshot `template`) in this frame, searched around
    /// `predicted` (Vision-normalised). Starts a tracker on it. Falls back to the prediction, unless
    /// `strict`: then nil when the object is not found.
    func reacquire(id: Int, template: CGImage, box: CGRect, predicted: CGRect, strict: Bool, in buffer: CVPixelBuffer) -> CGRect? {
        guard let found = Self.match(template: template, box: box, predicted: predicted, in: buffer) ?? (strict ? nil : predicted) else { return nil }
        let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: found))
        // The fast level, as in FastFollow: the accurate one took 35–90 ms a frame and slowed
        // EdgeTAM; this follower only needs to see whether a whole object moved (by 14 pt or more).
        request.trackingLevel = .fast
        lock.lock()
        if let old = requests.updateValue(request, forKey: id) { finish(old) }
        lock.unlock()
        return found
    }

    func track(_ ids: [Int], in buffer: CVPixelBuffer) -> [Int: (CGRect, Float)] {
        lock.lock()
        let active = ids.compactMap { id in requests[id].map { (id, $0) } }
        let done = finishing
        finishing = []
        lock.unlock()
        guard !active.isEmpty || !done.isEmpty else { return [:] }
        for r in done { r.isLastFrame = true }
        try? handler.perform(active.map(\.1) + done, on: buffer, orientation: .up)
        var out: [Int: (CGRect, Float)] = [:]
        for (id, request) in active {
            guard let obs = request.results?.first as? VNDetectedObjectObservation else { continue }
            request.inputObservation = obs
            out[id] = (obs.boundingBox, obs.confidence)
        }
        return out
    }

    // MARK: Finding the snapshot's object again

    /// Normalised cross-correlation on grey images a quarter of the sensor's size. The template is
    /// the snapshot's object turned into the sensor's orientation and scaled to the predicted size.
    static func match(template: CGImage, box: CGRect, predicted: CGRect, in buffer: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let sw = CVPixelBufferGetWidthOfPlane(buffer, 0), sh = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let f = 4
        let gw = sw / f, gh = sh / f
        // The predicted box in the grey image (top-left origin, sensor orientation).
        let px = predicted.minX * CGFloat(gw), py = (1 - predicted.maxY) * CGFloat(gh)
        let pw = predicted.width * CGFloat(gw), ph = predicted.height * CGFloat(gh)
        // Template: the snapshot crop (upright) turned to sensor orientation: sensor x = upright y,
        // sensor y = upright width − upright x. Its size is the predicted box's.
        let tw = max(8, min(64, Int(pw.rounded()))), th = max(8, min(64, Int(ph.rounded())))
        guard let crop = template.cropping(to: box.integral), let tpl = grey(crop, width: th, height: tw) else { return nil }
        // tpl is upright th × tw (width th, height tw) → rotate to sensor (width tw, height th).
        var t = [Float](repeating: 0, count: tw * th)
        for uy in 0..<tw { for ux in 0..<th { t[(th - 1 - ux) * tw + uy] = tpl[uy * th + ux] } }
        let tMean = t.reduce(0, +) / Float(t.count)
        let tDev = t.map { $0 - tMean }
        let tNorm = sqrt(tDev.reduce(0) { $0 + $1 * $1 })
        guard tNorm > 1 else { return nil }
        // Search ±1.5 template sizes around the prediction.
        let rx = Int(1.5 * Double(max(tw, 12))), ry = Int(1.5 * Double(max(th, 12)))
        let cx = Int(px + pw / 2) - tw / 2, cy = Int(py + ph / 2) - th / 2
        var best: (score: Float, x: Int, y: Int) = (-1, cx, cy)
        let step = 2
        var y0 = max(0, cy - ry)
        while y0 <= min(gh - th, cy + ry) {
            var x0 = max(0, cx - rx)
            while x0 <= min(gw - tw, cx + rx) {
                var sum: Float = 0, sumSq: Float = 0, cross: Float = 0
                for ty in 0..<th {
                    let sy = (y0 + ty) * f
                    for tx in 0..<tw {
                        let v = Float(luma[sy * row + (x0 + tx) * f])
                        sum += v
                        sumSq += v * v
                        cross += v * tDev[ty * tw + tx]
                    }
                }
                let n = Float(tw * th)
                let dev = sqrt(max(0, sumSq - sum * sum / n))
                let score = dev > 1 ? cross / (dev * tNorm) : -1
                if score > best.score { best = (score, x0, y0) }
                x0 += step
            }
            y0 += step
        }
        guard best.score > 0.55 else { return nil }
        let x = CGFloat(best.x) / CGFloat(gw), yTop = CGFloat(best.y) / CGFloat(gh)
        let w = CGFloat(tw) / CGFloat(gw), h = CGFloat(th) / CGFloat(gh)
        return CGRect(x: x, y: 1 - yTop - h, width: w, height: h)
    }

    /// The image scaled to `width` × `height` grey levels.
    static func grey(_ image: CGImage, width: Int, height: Int) -> [Float]? {
        var px = [UInt8](repeating: 0, count: width * height)
        // The context draws into the array's memory, so it may only live inside this closure.
        let drawn = px.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? px.map(Float.init) : nil
    }
}
