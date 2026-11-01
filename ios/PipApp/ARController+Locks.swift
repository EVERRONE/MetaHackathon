import ARKit
import PipCore
import QuartzCore
import RealityKit
import simd

/// Image locks: ARKit image tracking holds an outline on a flat face of its object, checked against EdgeTAM.
extension ARController {
    /// EdgeTAM measured the object on a frame where the lock drew its outline `mm` away. ARKit's
    /// image tracking can align a face with repeating parts (a keyboard, a remote's grid of buttons)
    /// one key or button off and hold it there (1 Nov: the reticle on alt instead of the Windows
    /// key, on ZONE SELECT instead of POWER, 21 mm off for seconds). EdgeTAM follows the target
    /// itself from SAM's mask: when the two disagree in the image by more than half the target's
    /// size (at least 6 mm at its distance) on 6 of the last 8 frames where the object lay still
    /// and EdgeTAM was sure of it, the lock is let go and EdgeTAM draws the outline.
    func lockComparison(_ id: Int, mm: Double, moving: Bool, sure: Bool) {
        // Only EdgeTAM's sure masks count: on 1 Nov an unsure one (score 3-4) with a stray depth
        // made Pip let go of a lock that was right.
        guard !moving, sure, let lock = imageLocks.values.first(where: { $0.markID == id && $0.seen && $0.tracked }), let m = marks[id] else { return }
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
        reconfigureImages()
    }

    /// Hands ARKit a reference image of the object a mark is on; once ARKit has checked it has
    /// enough texture, it follows the object and the mark goes with it.
    func lock(markID: Int, image: CGImage, physicalWidth: CGFloat, local: [[simd_float3]]) {
        guard marks[markID] != nil, physicalWidth > 0.01 else { return }
        let reference = ARReferenceImage(image, orientation: .up, physicalWidth: physicalWidth)
        reference.name = "pip-lock-\(markID)"
        reference.validate { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.onLockLog?("lock: mark \(markID % 1000) not trackable as an image (\(error.localizedDescription)); following in the image instead")
                    return
                }
                guard self.marks[markID] != nil else { return }
                // At most a few at once: the oldest lock gives way (by age: mark numbers wrap).
                if self.imageLocks.count >= Self.maxImageLocks, let oldest = self.imageLocks.values.min(by: { $0.created < $1.created }) {
                    self.imageLocks[oldest.name] = nil
                    // ARKit held that outline, not a room anchor: put it back on one where it is now.
                    if oldest.seen, !self.steered.contains(oldest.markID), let m = self.marks[oldest.markID] { self.place(m) }
                }
                self.imageLocks[reference.name!] = ImageLock(markID: markID, reference: reference, local: local)
                self.onLockLog?(String(format: "lock: mark %d locked to its object (%.0f mm wide reference)", markID % 1000, physicalWidth * 1000))
                self.reconfigureImages()
            }
        }
    }

    /// Runs the session again with the current reference images (no reset: tracking, anchors and
    /// the room map go on). Skipped while ARKit is still recognising a saved room.
    func reconfigureImages() {
        let names = Set(imageLocks.keys)
        guard names != lastImageSet, !awaitingFirstRelocalisation else { return }
        lastImageSet = names
        let config = Self.configuration(initialMap: nil)
        config.detectionImages = Set(imageLocks.values.map(\.reference))
        config.maximumNumberOfTrackedImages = min(Self.maxImageLocks, imageLocks.count)
        config.automaticImageScaleEstimationEnabled = true
        arView.session.run(config)
    }

    /// An image lock has found this mark's object (it held the outline, or holds it now).
    func lockSeen(_ id: Int) -> Bool { imageLocks.values.contains { $0.markID == id && $0.seen } }

    /// An image lock holds this mark's outline in this frame.
    func lockTracks(_ id: Int) -> Bool { imageLocks.values.contains { $0.markID == id && $0.seen && $0.tracked } }

    /// ARKit moved a locked object's image: its mark follows, in 3D.
    func updateLocks(_ changed: [ARAnchor]) {
        for case let anchor as ARImageAnchor in changed {
            guard let name = anchor.referenceImage.name, var lock = imageLocks[name], marks[lock.markID] != nil else { continue }
            let id = lock.markID
            if !lock.seen {
                // From now on ARKit's image pose holds the mark, not the room anchor.
                lock.seen = true
                if let a = anchors[id] { arView.session.remove(anchor: a.anchor) }
                anchors[id] = nil
                targetCorrections[id] = nil
                follower.stop(id)
                onLockLog?("lock: mark \(id % 1000) found on its object; following it in 3D")
            }
            lock.tracked = anchor.isTracked
            if anchor.isTracked { lock.lastTracked = CACurrentMediaTime() }
            imageLocks[name] = lock
            guard anchor.isTracked else { continue }
            // The lock holds the outline: EdgeTAM's drawing of it pauses, so EdgeTAM's lead does not
            // push the lock's outline and its older shape does not come back when ARKit loses the
            // image (EdgeTAM then takes up from the lock's outline).
            steerMotion[id] = nil
            steerShape[id] = nil
            steerHidden.remove(id)
            let s = Float(anchor.estimatedScaleFactor)
            let t = anchor.transform
            let world = lock.local.map { ring in ring.map { (t * simd_float4($0 * s, 1)).xyz } }
            marks[id] = AnchoredMark(id: id, world: world)
        }
    }
}
