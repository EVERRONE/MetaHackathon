import CoreGraphics
import PipCore
import QuartzCore
import simd

/// A SAM outline lifted onto the real surface in 3D, so it stays on the object while the phone moves.
///
/// A plane is fitted to the LiDAR points around the object (its orientation: a keyboard seen at an
/// angle) and moved to the object's own median depth (its position: a key top, a raised lever).
/// Every outline point is the intersection of its camera ray with that plane. If the fit is poor,
/// the outline falls back to a plane facing the camera at the median depth.
struct AnchoredMark {
    let id: Int
    /// How the plane was found, for the trace.
    let method: String
    /// ARKit's correction since the mark was placed: when it relocalises after the user comes
    /// back into the room, the mark's anchor moves and the outline moves with it.
    var correction = matrix_identity_float4x4
    /// A short glide from where the outline was drawn before a re-measurement, decaying to zero,
    /// so a correction moves the outline smoothly instead of making it jump.
    var glide = simd_float3.zero
    private let rawPolygons: [[simd_float3]]
    private let rawCentroid: simd_float3
    /// This measurement as a ray from the camera, for fusing it with later looks (nil for a
    /// remembered place rebuilt from storage).
    let observation: RayFusion.Observation?

    var polygons: [[simd_float3]] { rawPolygons.map { $0.map(apply) } }
    var centroid: simd_float3 { apply(rawCentroid) }
    /// Where the mark was placed, for its ARKit anchor.
    var placement: simd_float3 { rawCentroid }

    private func apply(_ p: simd_float3) -> simd_float3 {
        let q = correction * simd_float4(p, 1)
        return simd_float3(q.x, q.y, q.z) + glide
    }
    private let lift: (CGPoint) -> simd_float3
    private let imageCentre: CGPoint
    private let imageExtent: CGFloat

    init?(_ instance: SegmentInstance, snapshot: FrameSnapshot) {
        guard let outer = instance.outlinePoints.first, outer.count >= 3 else { return nil }
        let box = instance.boxRect
        let origin = simd_float3(snapshot.cameraTransform.columns.3.x, snapshot.cameraTransform.columns.3.y, snapshot.cameraTransform.columns.3.z)

        // Depth samples inside the object, and on the surface around it.
        // The object's own depth from high-confidence samples when there are enough.
        let confident = Self.samples(in: box, keep: { Self.contains(outer, $0) }, snapshot: snapshot, grid: 14, minConfidence: 2)
        let inside = confident.count >= 4 ? confident : Self.samples(in: box, keep: { Self.contains(outer, $0) }, snapshot: snapshot, grid: 14)
        let around = Self.samples(in: box.insetBy(dx: -box.width * 1.2, dy: -box.height * 1.2), keep: { _ in true }, snapshot: snapshot, grid: 20)
        // Without usable LiDAR depth (a black or glossy surface, too far, the first frames) the
        // outline still goes up, at an assumed arm's length, rather than not at all.
        let median = Self.median((inside.count >= 3 ? inside : around).map(\.depth)) ?? Self.assumedDepth

        let rayPoint = { (p: CGPoint) in snapshot.worldPoint(sensor: snapshot.sensorPoint(p), depth: 1) }
        let flat = { (p: CGPoint) in snapshot.worldPoint(sensor: snapshot.sensorPoint(p), depth: median) }

        var lift = flat
        var method = (inside.count >= 3 || around.count >= 3) ? "facing camera" : "assumed depth"
        if let plane = Self.fitPlane(around.map(\.world)) {
            // Orientation from the surroundings, position from the object itself.
            let anchor = flat(instance.centre)
            let n = plane.normal
            let viewDir = simd_normalize(anchor - origin)
            if abs(simd_dot(n, viewDir)) > 0.2 {
                lift = { p in
                    let dir = simd_normalize(rayPoint(p) - origin)
                    let denom = simd_dot(n, dir)
                    guard abs(denom) > 0.08 else { return flat(p) }
                    let t = simd_dot(n, anchor - origin) / denom
                    return t > 0.05 && t < 10 ? origin + dir * t : flat(p)
                }
                method = "surface plane"
            }
        }

        id = instance.id
        rawPolygons = instance.outlinePoints.map { $0.map(lift) }
        let centroid = lift(instance.centre)
        rawCentroid = centroid
        imageCentre = instance.centre
        imageExtent = max(box.width, box.height)
        self.lift = lift
        self.method = method

        // How far this measurement can be trusted: LiDAR on the object itself is good to ~1.5 cm,
        // the surroundings' depth less, an assumed depth not at all. Sideways, SAM's outline centre
        // moves by a few pixels (more for big objects) between measurements.
        let distance = simd_distance(centroid, origin)
        let sigma: Float? = confident.count >= 4 ? 0.015 : (inside.count >= 3 ? 0.03 : (around.count >= 3 ? 0.06 : nil))
        let focal = snapshot.intrinsics[0][0] * Float(CGFloat(snapshot.image.height) / snapshot.sensorSize.width)
        let lateral = distance * Float(max(3, 0.04 * imageExtent)) / max(focal, 100)
        observation = RayFusion.Observation(origin: origin, direction: centroid - origin, distance: sigma == nil ? nil : distance,
                                            distanceSigma: sigma ?? 1, lateralSigma: lateral, time: CACurrentMediaTime())
    }

    private init(id: Int, method: String, rawPolygons: [[simd_float3]], rawCentroid: simd_float3, observation: RayFusion.Observation?,
                 lift: @escaping (CGPoint) -> simd_float3, imageCentre: CGPoint, imageExtent: CGFloat) {
        self.id = id
        self.method = method
        self.rawPolygons = rawPolygons
        self.rawCentroid = rawCentroid
        self.observation = observation
        self.lift = lift
        self.imageCentre = imageCentre
        self.imageExtent = imageExtent
    }

    /// The same outline moved so its centre is at `target` (a fused position): scaled about the
    /// camera it was measured from, so it still looks the same from there, then shifted sideways.
    /// A depth error is corrected without changing how the outline fits from that view.
    func relocated(to target: simd_float3) -> AnchoredMark {
        guard let o = observation?.origin else { return self }
        let before = simd_distance(rawCentroid, o)
        guard before > 0.01 else { return self }
        let s = simd_distance(target, o) / before
        let shift = target - (o + (rawCentroid - o) * s)
        let move = { (p: simd_float3) in o + (p - o) * s + shift }
        let oldLift = lift
        return AnchoredMark(id: id, method: method + " + fused", rawPolygons: rawPolygons.map { $0.map(move) }, rawCentroid: move(rawCentroid),
                            observation: observation, lift: { move(oldLift($0)) }, imageCentre: imageCentre, imageExtent: imageExtent)
    }

    /// A remembered place, rebuilt from its saved outline in world space.
    init(id: Int, world polygons: [[simd_float3]]) {
        self.id = id
        method = "remembered"
        rawPolygons = polygons
        let all = polygons.flatMap { $0 }
        let centre = all.isEmpty ? .zero : all.reduce(.zero, +) / Float(all.count)
        rawCentroid = centre
        imageCentre = .zero
        imageExtent = 0
        lift = { _ in centre }
        observation = nil
    }

    /// Start and end of a straight arrow for `move`, in world space.
    func arrow(_ direction: MoveDirection) -> (simd_float3, simd_float3) {
        let len = max(40, imageExtent * 0.55)
        let (dx, dy): (CGFloat, CGFloat)
        switch direction {
        case .up: (dx, dy) = (0, -1)
        case .down: (dx, dy) = (0, 1)
        case .left: (dx, dy) = (-1, 0)
        case .right: (dx, dy) = (1, 0)
        case .in, .out: (dx, dy) = (0, 0)
        }
        return (centroid, apply(lift(CGPoint(x: imageCentre.x + dx * len, y: imageCentre.y + dy * len))))
    }

    // MARK: Depth

    static let assumedDepth: Float = 0.5

    private struct Sample { let depth: Float; let world: simd_float3 }

    private static func samples(in rect: CGRect, keep: (CGPoint) -> Bool, snapshot: FrameSnapshot, grid n: Int, minConfidence: UInt8 = 1) -> [Sample] {
        let bounds = CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height)
        let r = rect.intersection(bounds)
        guard !r.isNull, r.width > 1, r.height > 1 else { return [] }
        var out: [Sample] = []
        for i in 0..<n {
            for j in 0..<n {
                let p = CGPoint(x: r.minX + (CGFloat(i) + 0.5) / CGFloat(n) * r.width, y: r.minY + (CGFloat(j) + 0.5) / CGFloat(n) * r.height)
                guard keep(p) else { continue }
                let q = snapshot.sensorPoint(p)
                guard let d = snapshot.depth(atSensor: q, minConfidence: minConfidence) else { continue }
                out.append(Sample(depth: d, world: snapshot.worldPoint(sensor: q, depth: d)))
            }
        }
        return out
    }

    private static func median(_ xs: [Float]) -> Float? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s[s.count / 2]
    }

    /// Least-squares plane with one round of outlier rejection (points more than 1.5 cm off).
    private static func fitPlane(_ points: [simd_float3]) -> (centre: simd_float3, normal: simd_float3)? {
        guard points.count >= 12 else { return nil }
        func fit(_ pts: [simd_float3]) -> (simd_float3, simd_float3)? {
            let c = pts.reduce(simd_float3.zero, +) / Float(pts.count)
            var cov = simd_float3x3(0)
            for p in pts {
                let d = p - c
                cov += simd_float3x3(columns: (d * d.x, d * d.y, d * d.z))
            }
            // Smallest eigenvector of cov = largest of (trace·I − cov), by power iteration.
            let shift = cov[0][0] + cov[1][1] + cov[2][2]
            let b = simd_float3x3(diagonal: simd_float3(repeating: shift)) - cov
            var v = simd_normalize(simd_float3(0.3, 0.5, 0.8))
            // Converges like (λ1/(λ1+λ2))^n; 200 steps is precise even for elongated patches.
            for _ in 0..<200 { v = simd_normalize(b * v) }
            return v.x.isFinite ? (c, v) : nil
        }
        guard let (c0, n0) = fit(points) else { return nil }
        let inliers = points.filter { abs(simd_dot($0 - c0, n0)) < 0.015 }
        guard inliers.count >= max(10, points.count / 2), let (c1, n1) = fit(inliers) else { return nil }
        return (c1, n1)
    }

    private static func contains(_ ring: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}
