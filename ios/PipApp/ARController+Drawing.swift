import ARKit
import PipCore
import QuartzCore
import RealityKit
import simd

/// Drawing every frame: outlines follow their measurements, and the overlay draws the cues on them.
extension ARController {
    func renderNow() {
        let now = CACurrentMediaTime()
        // The camera frame on screen: the outline must match it, not the world at this instant
        // (ARKit's frame is some 40-60 ms old when it is drawn).
        let shownFrame = arView.session.currentFrame?.timestamp ?? now
        let dt = lastRender > 0 ? min(0.1, now - lastRender) : 1.0 / 60
        lastRender = now
        // Steered outlines take up their latest mask (see `steerShape`).
        for (id, shape) in steerShape where steered.contains(id) && shape.shown != shape.target {
            guard let current = marks[id] else { continue }
            let moving = steerMotion[id].map { simd_length($0.velocity) > 0 } ?? false
            let k = Float(1 - exp(-dt / (moving ? Self.followMoving : Self.followStill)))
            var shown = shape.shown
            var settled = true
            for i in shown.indices {
                shown[i] += (shape.target[i] - shown[i]) * k
                if simd_distance(shown[i], shape.target[i]) > 0.0002 { settled = false }
            }
            if settled { shown = shape.target }
            steerShape[id] = (shown, shape.target)
            var m = AnchoredMark(id: id, world: [shown])
            m.lead = current.lead
            marks[id] = m
        }
        // Corrections and re-measurements ease in over about a fifth of a second.
        for (id, var m) in marks {
            var changed = false
            if let target = targetCorrections[id] {
                m.correction = Self.ease(m.correction, towards: target, by: 0.25)
                changed = true
            }
            if simd_length(m.glide) > 0.0005 {
                m.glide *= 0.8
                changed = true
            } else if m.glide != .zero {
                m.glide = .zero
                changed = true
            }
            // A moving object followed in the image: drawn where it has got to by the frame on screen.
            if let motion = planarMotion[id], planarFollowed.contains(id) {
                var lead = motion.velocity * Float(min(max(0, shownFrame - motion.time), 0.1))
                if simd_length(lead) > 0.03 { lead = simd_normalize(lead) * 0.03 }
                if lead != m.lead { m.lead = lead; changed = true }
            } else if let motion = steerMotion[id] {
            // A moving object steered by EdgeTAM: drawn where it has got to since its mask.
                // Ahead by the mask's age at the shown frame, and by the time the drawn outline
                // takes to follow it.
                var lead = motion.velocity * Float(min(max(0, shownFrame - motion.time) + Self.followMoving, Self.maxLead))
                if simd_length(lead) > 0.05 { lead = simd_normalize(lead) * 0.05 }
                // Better, for a moving object: where the fast tracker saw it go since the mask's
                // frame, from the mask's own place (the drawn shape's easing made up for).
                if let live = edgeTAM.liveShift(id: id, since: motion.time, shown: shownFrame), let shape = steerShape[id] {
                    let s = min(1, max(0, (live.speed - 0.03) / 0.05))
                    let w = s * s * (3 - 2 * s)
                    var tracked = live.shift + Contour.centroid(shape.target) - Contour.centroid(shape.shown)
                    if simd_length(tracked) > 0.25 { tracked = simd_normalize(tracked) * 0.25 }
                    lead = tracked * w + lead * (1 - w)
                }
                if lead != m.lead { m.lead = lead; changed = true }
            }
            if changed { marks[id] = m }
        }
        // Marks riding along with the one EdgeTAM follows (see `takeRiders`): at their offset from
        // its drawn centre, with its lead.
        for (id, ride) in riders {
            guard let leader = marks[ride.leader], let shape = steerShape[ride.leader] else { continue }
            let centre = Contour.centroid(shape.shown)
            var m = AnchoredMark(id: id, world: ride.offset.map { ring in ring.map { $0 + centre } })
            m.lead = leader.lead
            marks[id] = m
        }
        // Also for one followed in the image: EdgeTAM, still following it, measures what is drawn.
        for id in steered.union(planarFollowed) {
            guard let m = marks[id], planarFollowed.contains(id) ? !planarHidden.contains(id) : !steerHidden.contains(id) else { continue }
            var h = drawnHistory[id] ?? []
            if h.last?.t != shownFrame { h.append((shownFrame, m.centroid)) }
            if h.count > 90 { h.removeFirst(h.count - 90) }
            drawnHistory[id] = h
        }
        trackVisibility(now: now)
        board.tick(now)
        var adjust = follower.adjust
        // Steered and lost while it moved: hidden until EdgeTAM sees it again.
        for id in steerHidden {
            adjust[id] = ImageFollower.Adjust(from: .zero, to: .zero, scale: 1, hidden: true)
        }
        // Followed in the image and lost while it moved: hidden until found again.
        for id in planarHidden { adjust[id] = ImageFollower.Adjust(from: .zero, to: .zero, scale: 1, hidden: true) }
        // Riding along with an object EdgeTAM lost while it moved: hidden with it.
        for (id, ride) in riders where steerHidden.contains(ride.leader) {
            adjust[id] = ImageFollower.Adjust(from: .zero, to: .zero, scale: 1, hidden: true)
        }
        overlay.adjust = adjust
        overlay.unconfirmed = carried.union(planarUnsure).union(tracks.compactMap { $0.value.unconfirmed ? $0.key : nil })
        // Points behind the camera are never drawn (a projection would mirror them onto the
        // view); the edge arrow points the way instead, from the camera's own frame.
        let view = arView.session.currentFrame?.camera.viewMatrix(for: .portrait)
        func inCamera(_ p: simd_float3) -> simd_float4? { view.map { $0 * simd_float4(p, 1) } }
        overlay.render(board.annotations, now: now, marks: marks, project: { [arView] p in
            if let c = inCamera(p), c.z > -0.05 { return nil }
            return arView.project(p)
        }, direction: { p in
            // x right and y up in the portrait camera frame; straight behind: turn right.
            guard let c = inCamera(p) else { return nil }
            return abs(c.x) + abs(c.y) < 1e-4 ? CGVector(dx: 1, dy: 0) : CGVector(dx: CGFloat(c.x), dy: CGFloat(-c.y))
        })
        shots.frame(now: now, cuesDrawn: board.annotations.contains { $0.cue.isDrawn && !$0.cue.marks.isEmpty }, arView: arView, overlay: overlay)
    }

    /// Pointed-at objects with a cue on screen, followed in the image (see ImageFollower).
    func followObjects(_ frame: ARFrame) {
        let locked = steered.union(riders.keys).union(planarFollowed)
        let shownIDs = Set(board.annotations.flatMap { $0.cue.marks }).filter { $0 < Self.placeMarkBase && tracks[$0] != nil && !locked.contains($0) }
        guard !shownIDs.isEmpty else { return }
        var shown: [(id: Int, box: CGRect)] = []
        for id in shownIDs.sorted() {
            guard let m = marks[id] else { continue }
            let pts = m.polygons.flatMap { $0 }.compactMap { arView.project($0 - m.glide) }
            guard pts.count >= 3 else { continue }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            guard box.intersects(arView.bounds) else { continue }
            shown.append((id, box))
        }
        follower.update(frame: frame, shown: shown, viewSize: arView.bounds.size)
    }

    /// A box in screen points as pixels of `snapshot` (taken from the current frame).
    func snapshotBox(screen r: CGRect, snapshot: FrameSnapshot) -> CGRect? {
        guard let frame = arView.session.currentFrame, arView.bounds.width > 0 else { return nil }
        let size = arView.bounds.size
        let toImage = frame.displayTransform(for: .portrait, viewportSize: size).inverted()
        let n = CGRect(x: r.minX / size.width, y: r.minY / size.height, width: r.width / size.width, height: r.height / size.height)
        let img = n.applying(toImage).standardized
        // Sensor (landscape) normalised → upright pixels: upright x = (1 − y) · width, upright y = x · height.
        let w = CGFloat(snapshot.image.width), h = CGFloat(snapshot.image.height)
        return CGRect(x: (1 - img.maxY) * w, y: img.minX * h, width: img.height * w, height: img.width * h)
    }

    /// Notes when each object leaves and re-enters the view, so it is checked when it comes back.
    func trackVisibility(now: TimeInterval) {
        guard !tracks.isEmpty else { return }
        let bounds = arView.bounds
        for (id, var track) in tracks {
            guard let m = marks[id] else { continue }
            let inView = arView.project(m.centroid).map { bounds.contains($0) } ?? false
            if track.noteVisible(inView, now: now) { tracks[id] = track }
        }
    }

    /// A rigid transform part of the way towards another: position eased linearly, rotation along the arc.
    static func ease(_ a: simd_float4x4, towards b: simd_float4x4, by t: Float) -> simd_float4x4 {
        let qa = simd_quatf(a), qb = simd_quatf(b)
        var m = simd_float4x4(simd_slerp(qa, qb, t))
        m.columns.3 = simd_mix(a.columns.3, b.columns.3, simd_float4(repeating: t))
        m.columns.3.w = 1
        return m
    }
}
