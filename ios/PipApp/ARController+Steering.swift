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
        let first = !steered.contains(id)
        if first {
            riders[id] = nil
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
        if first { takeRiders(id) }
    }

    /// EdgeTAM follows one object at a time. The other marks of the same look on the same object
    /// (the keys of one keyboard: the model's on="keyboard", within 40 cm) ride along with the one
    /// it follows, at the offset they had: when the keyboard is slid, all its keys go with it (on
    /// 1 Nov two of three keys stayed behind on room anchors). A lock that finds the object takes
    /// them over (one lock carries every key of it, see GuideModel.lockToObject).
    func takeRiders(_ leader: Int) {
        guard let on = tracks[leader]?.spec?.on, let shape = steerShape[leader] else { return }
        let centre = Contour.centroid(shape.shown)
        var taken: [Int] = []
        for (id, m) in marks where id != leader && id / 1000 == leader / 1000 && id < Self.foundMarkBase {
            guard tracks[id]?.spec?.on == on, !steered.contains(id), !lockSeen(id), riders[id] == nil,
                  simd_distance(m.centroid, centre) < 0.4 else { continue }
            riders[id] = (leader, m.polygons.map { ring in ring.map { $0 - centre } })
            if let a = anchors[id] { arView.session.remove(anchor: a.anchor) }
            anchors[id] = nil
            targetCorrections[id] = nil
            follower.stop(id)
            taken.append(id)
        }
        if !taken.isEmpty {
            onLockLog?("edgetam: mark\(taken.count > 1 ? "s" : "") \(taken.sorted().map { String($0 % 1000) }.joined(separator: ",")) ride along with mark \(leader % 1000) (\(on))")
        }
    }

    /// Back on room anchors where they are drawn now, followed in the image and measured afresh
    /// (their views from before may be of another place: that first measurement is no drift of the
    /// room): outlines that EdgeTAM, a lock or another mark carried until now.
    func reanchor(_ ids: [Int]) {
        guard !ids.isEmpty else { return }
        let snap = snapshot()
        let boxes = snap.map { visibleMarkBoxes(in: $0) } ?? []
        for id in ids {
            guard var m = marks[id] else { continue }
            m.lead = .zero
            place(m)
            if let track = tracks[id] { tracks[id] = ObjectTrack(place: track.spec, now: CACurrentMediaTime()) }
            if let snap, let box = boxes.first(where: { $0.id == id })?.box { follower.start(id, image: snap.image, box: box) }
        }
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
        let riding = riders.filter { $0.value.leader == id }.map(\.key)
        riding.forEach { riders[$0] = nil }
        if steerHidden.remove(id) != nil {
            onLockLog?("edgetam: mark \(id % 1000) moved away unseen and is no longer followed; its outline is dropped")
            removeMarks { $0 == id || riding.contains($0) }
            return
        }
        let back = (lockSeen(id) ? [] : [id]) + riding.filter { !lockSeen($0) }
        reanchor(back)
        if !back.isEmpty { onLockLog?("edgetam: mark\(back.count > 1 ? "s" : "") \(back.sorted().map { String($0 % 1000) }.joined(separator: ",")) held by room anchors again") }
    }
}
