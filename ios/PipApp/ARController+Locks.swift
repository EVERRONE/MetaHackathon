import ARKit
import PipCore
import QuartzCore
import RealityKit
import simd

/// Image locks: ARKit image tracking holds outlines on a flat face of their object, checked against EdgeTAM.
extension ARController {
    /// EdgeTAM measured the object on a frame where the lock drew its outline `mm` away. ARKit's
    /// image tracking can align a face with repeating parts (a keyboard, a remote's grid of buttons)
    /// one key or button off and hold it there (1 Nov: the reticle on alt instead of the Windows
    /// key, on ZONE SELECT instead of POWER, 21 mm off for seconds). EdgeTAM follows the target
    /// itself from SAM's mask: when the two disagree in the image by more than half the target's
    /// size (at least 6 mm at its distance) on 6 of the last 8 frames where the object lay still
    /// and EdgeTAM was sure of it, the lock is let go and EdgeTAM draws the outline (the other
    /// marks on that face go back on room anchors: the face was off for them too).
    func lockComparison(_ id: Int, mm: Double, moving: Bool, sure: Bool) {
        // Only EdgeTAM's sure masks count: on 1 Nov an unsure one (score 3-4) with a stray depth
        // made Pip let go of a lock that was right.
        guard !moving, sure, let lock = imageLocks.values.first(where: { $0.marks[id] != nil && $0.seen && $0.tracked }), let m = marks[id] else { return }
        let pts = m.polygons.flatMap { $0 }
        guard let first = pts.first else { return }
        var lo = first, hi = first
        for p in pts { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let size = Double(simd_reduce_max(hi - lo)) * 1000
        let limit = max(6, 0.5 * size)
        var recent = lockDisagreements[id] ?? []
        recent.append(mm > limit)
        if recent.count > 8 { recent.removeFirst(recent.count - 8) }
        lockDisagreements[id] = recent
        guard recent.count >= 8, recent.filter({ $0 }).count >= 6 else { return }
        imageLocks[lock.name] = nil
        lockDisagreements[id] = nil
        onLockLog?(String(format: "lock: mark %d let go: its face was aligned %.0f mm off the target (EdgeTAM agrees with itself, not with the lock); EdgeTAM draws it now", id % 1000, mm))
        released(lock)
    }

    /// Hands ARKit one reference image of the object these marks are on (the keys of one keyboard
    /// share it); once ARKit has checked it has enough texture, it follows the object and every
    /// mark on it goes with it, in 3D.
    func lock(_ outlines: [Int: [[simd_float3]]], image: CGImage, physicalWidth: CGFloat) {
        guard outlines.keys.contains(where: { marks[$0] != nil }), physicalWidth > 0.01 else { return }
        let reference = ARReferenceImage(image, orientation: .up, physicalWidth: physicalWidth)
        lockSerial += 1
        // A name of its own: mark numbers come back in later looks, and an old picture can still
        // be in ARKit's set (see `reconfigureImages`).
        reference.name = "pip-lock-\(lockSerial)"
        let label = outlines.keys.sorted().map { String($0 % 1000) }.joined(separator: ",")
        reference.validate { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.onLockLog?("lock: marks \(label) not trackable as an image (\(error.localizedDescription)); following in the image instead")
                    return
                }
                // Marks still there, and not locked already (found again after a fresh start
                // while their first lock was being made: one picture of an object is enough).
                let live = outlines.filter { o in self.marks[o.key] != nil && !self.imageLocks.values.contains { $0.marks[o.key] != nil } }
                guard !live.isEmpty else { return }
                // At most a few at once: the oldest lock gives way (by age: mark numbers wrap).
                if self.imageLocks.count >= Self.maxImageLocks, let oldest = self.imageLocks.values.min(by: { $0.created < $1.created }) {
                    self.imageLocks[oldest.name] = nil
                    self.released(oldest)
                }
                self.imageLocks[reference.name!] = ImageLock(marks: live, reference: reference)
                self.onLockLog?(String(format: "lock: mark%@ %@ locked to their object (%.0f mm wide reference)", live.count > 1 ? "s" : "", label, physicalWidth * 1000))
                self.reconfigureImages()
            }
        }
    }

    /// A lock that held its marks no longer does: each goes back on a room anchor where it is
    /// drawn now, unless EdgeTAM draws it or it rides along with the mark EdgeTAM follows.
    func released(_ lock: ImageLock) {
        guard lock.seen else { return }
        reanchor(lock.marks.keys.filter { marks[$0] != nil && !steered.contains($0) && riders[$0] == nil })
    }

    /// How long at least between two re-runs of the session for its reference images.
    static let reconfigureEvery: TimeInterval = 3

    /// Runs the session again with the current reference images (no reset: tracking, anchors and
    /// the room map go on). Each such run makes ARKit tear its image detection down and build it
    /// again; on 1 Nov, after six runs within a minute (one per lock and per lock removed), ARKit
    /// crashed in that teardown (a released detection still in use on its own queue). So a run is
    /// made only when a new picture needs looking for, never for one that goes (it stays in
    /// ARKit's set until the next run; its anchors are ignored), and at most every
    /// `reconfigureEvery` seconds: what comes in between waits for one run. Skipped while ARKit
    /// is still recognising a saved room.
    func reconfigureImages() {
        guard !awaitingFirstRelocalisation else { return }
        let names = Set(imageLocks.keys)
        guard !names.isSubset(of: lastImageSet) else { return }
        let wait = lastImageRun + Self.reconfigureEvery - CACurrentMediaTime()
        guard wait <= 0 else {
            if !imageRunScheduled {
                imageRunScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    self?.imageRunScheduled = false
                    self?.reconfigureImages()
                }
            }
            return
        }
        lastImageRun = CACurrentMediaTime()
        lastImageSet = names
        let config = Self.configuration(initialMap: nil)
        config.detectionImages = Set(imageLocks.values.map(\.reference))
        config.maximumNumberOfTrackedImages = min(Self.maxImageLocks, imageLocks.count)
        config.automaticImageScaleEstimationEnabled = true
        arView.session.run(config)
    }

    /// The session was run again without reference images (a fresh start): every picture has
    /// to be looked for again.
    func imagesCleared() {
        lastImageSet = []
        lastImageRun = CACurrentMediaTime()
    }

    /// An image lock has found this mark's object (it held the outline, or holds it now).
    func lockSeen(_ id: Int) -> Bool { imageLocks.values.contains { $0.marks[id] != nil && $0.seen } }

    /// An image lock holds this mark's outline in this frame.
    func lockTracks(_ id: Int) -> Bool { imageLocks.values.contains { $0.marks[id] != nil && $0.seen && $0.tracked } }

    /// ARKit moved a locked object's image: its marks follow, in 3D.
    func updateLocks(_ changed: [ARAnchor]) {
        for case let anchor as ARImageAnchor in changed {
            guard let name = anchor.referenceImage.name, var lock = imageLocks[name] else { continue }
            let ids = lock.marks.keys.filter { marks[$0] != nil }
            guard !ids.isEmpty else { continue }
            if !lock.seen {
                // From now on ARKit's image pose holds the marks, not room anchors or other marks.
                lock.seen = true
                for id in ids {
                    if let a = anchors[id] { arView.session.remove(anchor: a.anchor) }
                    anchors[id] = nil
                    targetCorrections[id] = nil
                    follower.stop(id)
                    riders[id] = nil
                }
                onLockLog?("lock: mark\(ids.count > 1 ? "s" : "") \(ids.sorted().map { String($0 % 1000) }.joined(separator: ",")) found on their object; following it in 3D")
            }
            lock.tracked = anchor.isTracked
            if anchor.isTracked { lock.lastTracked = CACurrentMediaTime() }
            imageLocks[name] = lock
            guard anchor.isTracked else { continue }
            let s = Float(anchor.estimatedScaleFactor)
            let t = anchor.transform
            for id in ids {
                // The lock holds the outline: EdgeTAM's drawing of it pauses, so EdgeTAM's lead does
                // not push the lock's outline and its older shape does not come back when ARKit
                // loses the image (EdgeTAM then takes up from the lock's outline).
                steerMotion[id] = nil
                steerShape[id] = nil
                steerHidden.remove(id)
                guard let local = lock.marks[id] else { continue }
                marks[id] = AnchoredMark(id: id, world: local.map { ring in ring.map { (t * simd_float4($0 * s, 1)).xyz } })
            }
        }
    }
}
