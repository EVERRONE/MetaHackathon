import ARKit
import PipCore
import QuartzCore
import RealityKit
import simd

/// EdgeTAM's mask draws the outline of the object it follows (see EdgeTAMFollower).
extension ARController {
    /// EdgeTAM saw the object: its outline is the mask's, in the room. A flat face that ARKit's image
    /// tracking holds is more exact (under a millimetre to 1.5 mm): there the lock keeps the outline.
    func steer(_ id: Int, world: [[simd_float3]], velocity: simd_float3 = .zero, at time: TimeInterval = CACurrentMediaTime()) {
        guard marks[id] != nil else { return }
        if lockTracks(id) { return }
        if !steered.contains(id) {
            // From now on EdgeTAM holds the outline, not the room anchor or the box tracker.
            steered.insert(id)
            if let a = anchors[id] { arView.session.remove(anchor: a.anchor) }
            anchors[id] = nil
            targetCorrections[id] = nil
            follower.stop(id)
            onLockLog?("edgetam: mark \(id % 1000) is drawn from EdgeTAM's mask")
        }
        steerHidden.remove(id)
        guard let ring = world.first, ring.count >= 3 else { return }
        var target = Contour.resample(ring, count: Self.steerPoints)
        // From the outline drawn so far (the first time: SAM's), unless the object was found again
        // somewhere else: then it is drawn there at once rather than sliding across the room.
        if let drawn = steerShape[id]?.shown ?? marks[id]?.polygons.first.map({ Contour.resample($0, count: Self.steerPoints) }) {
            target = Contour.aligned(target, to: drawn, eitherWay: steerShape[id] == nil)
            let jumped = simd_distance(Contour.centroid(target), Contour.centroid(drawn)) > 0.25
            steerShape[id] = (jumped ? target : drawn, target)
        } else {
            steerShape[id] = (target, target)
        }
        var m = AnchoredMark(id: id, world: [steerShape[id]!.shown])
        m.lead = marks[id]?.lead ?? .zero
        marks[id] = m
        steerMotion[id] = (velocity, time)
    }

    /// EdgeTAM does not see the object: if it was moving, its outline waits hidden until it is seen
    /// again; if not, it stays where the object was (out of view, or covered for a moment).
    func steerLost(_ id: Int, moving: Bool) {
        guard steered.contains(id), moving, !lockTracks(id) else { return }
        steerHidden.insert(id)
    }

    /// EdgeTAM follows another object now, or stopped. An outline it drew goes back on a room
    /// anchor where it was last measured, and the image follower and re-measuring take it up
    /// again; one hidden because its object moved away unseen is dropped: where it is now, Pip
    /// does not know.
    func unsteer(_ id: Int) {
        guard steered.remove(id) != nil else { return }
        steerMotion[id] = nil
        steerShape[id] = nil
        drawnHistory[id] = nil
        if steerHidden.remove(id) != nil {
            onLockLog?("edgetam: mark \(id % 1000) moved away unseen and is no longer followed; its outline is dropped")
            removeMarks { $0 == id }
            return
        }
        guard var m = marks[id], !lockSeen(id) else { return }
        m.lead = .zero
        place(m)
        // Its views from before EdgeTAM took over may be of another place (it was moved): it is
        // measured afresh, and that first measurement is no drift of the room.
        if let track = tracks[id] { tracks[id] = ObjectTrack(place: track.spec, now: CACurrentMediaTime()) }
        if let snap = snapshot(), let box = visibleMarkBoxes(in: snap).first(where: { $0.id == id })?.box {
            follower.start(id, image: snap.image, box: box)
        }
        onLockLog?("edgetam: mark \(id % 1000) is held by a room anchor again")
    }
}
