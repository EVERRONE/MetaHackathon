import CoreGraphics
import PipCore
import simd

/// A SAM outline lifted onto the real surface in 3D, so it stays on the object while the phone moves.
///
/// A plane is fitted to the LiDAR points around the object (its orientation: a keyboard seen at an
/// angle) and moved to the object's own median depth (its position: a key top, a raised lever).
/// Every outline point is the intersection of its camera ray with that plane. If the fit is poor,
/// the outline falls back to a plane facing the camera at the median depth.
struct AnchoredMark {
    let id: Int
    let polygons: [[simd_float3]]
    let centroid: simd_float3
    /// How the plane was found, for the trace.
    let method: String
    private let lift: (CGPoint) -> simd_float3
    private let imageCentre: CGPoint
    private let imageExtent: CGFloat

    init?(_ instance: SegmentInstance, snapshot: FrameSnapshot) {
        guard let outer = instance.outlinePoints.first, outer.count >= 3 else { return nil }
        let box = instance.boxRect
        let origin = simd_float3(snapshot.cameraTransform.columns.3.x, snapshot.cameraTransform.columns.3.y, snapshot.cameraTransform.columns.3.z)

        // Depth samples inside the object, and on the surface around it.
        let inside = Self.samples(in: box, keep: { Self.contains(outer, $0) }, snapshot: snapshot, grid: 12)
        let around = Self.samples(in: box.insetBy(dx: -box.width * 1.2, dy: -box.height * 1.2), keep: { _ in true }, snapshot: snapshot, grid: 20)
        guard let median = Self.median((inside.count >= 3 ? inside : around).map(\.depth)) else { return nil }

        let rayPoint = { (p: CGPoint) in snapshot.worldPoint(sensor: snapshot.sensorPoint(p), depth: 1) }
        let flat = { (p: CGPoint) in snapshot.worldPoint(sensor: snapshot.sensorPoint(p), depth: median) }

        var lift = flat
        var method = "facing camera"
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
        polygons = instance.outlinePoints.map { $0.map(lift) }
        centroid = lift(instance.centre)
        imageCentre = instance.centre
        imageExtent = max(box.width, box.height)
        self.lift = lift
        self.method = method
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
        return (centroid, lift(CGPoint(x: imageCentre.x + dx * len, y: imageCentre.y + dy * len)))
    }

    // MARK: Depth

    private struct Sample { let depth: Float; let world: simd_float3 }

    private static func samples(in rect: CGRect, keep: (CGPoint) -> Bool, snapshot: FrameSnapshot, grid n: Int) -> [Sample] {
        let bounds = CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height)
        let r = rect.intersection(bounds)
        guard !r.isNull, r.width > 1, r.height > 1 else { return [] }
        var out: [Sample] = []
        for i in 0..<n {
            for j in 0..<n {
                let p = CGPoint(x: r.minX + (CGFloat(i) + 0.5) / CGFloat(n) * r.width, y: r.minY + (CGFloat(j) + 0.5) / CGFloat(n) * r.height)
                guard keep(p) else { continue }
                let q = snapshot.sensorPoint(p)
                guard let d = snapshot.depth(atSensor: q, minConfidence: 1) else { continue }
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
            for _ in 0..<40 { v = simd_normalize(b * v) }
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
