import simd

/// Where an object really is, from several looks at it: each look is a ray from the camera
/// through the object's centre, with the LiDAR distance along that ray when there was one.
///
/// One look pins the object only as well as its depth was measured: a few centimetres off and the
/// outline slides as soon as the phone moves. Two looks from different places cross, and the
/// crossing does not depend on depth at all. Every measurement is weighted by how far it can be
/// trusted, so more looks only ever make the estimate firmer (least squares over all rays).
public enum RayFusion {
    public struct Observation: Equatable, Sendable {
        /// Camera position when the object was measured, in world space.
        public var origin: simd_float3
        /// Unit direction from the camera to the object's centre.
        public var direction: simd_float3
        /// Distance along the ray from LiDAR, if it measured the object.
        public var distance: Float?
        /// How far the distance can be off, in metres (1.5 cm for confident LiDAR on a surface).
        public var distanceSigma: Float
        /// How far the ray can be off sideways at the object, in metres (the outline's centre
        /// moves by a few pixels between measurements).
        public var lateralSigma: Float
        public var time: Double

        public init(origin: simd_float3, direction: simd_float3, distance: Float?, distanceSigma: Float, lateralSigma: Float, time: Double) {
            self.origin = origin
            self.direction = simd_normalize(direction)
            self.distance = distance
            self.distanceSigma = max(distanceSigma, 0.002)
            self.lateralSigma = max(lateralSigma, 0.0005)
            self.time = time
        }

        /// The point this look alone puts the object at.
        public var point: simd_float3? { distance.map { origin + direction * $0 } }
    }

    /// The least-squares point for all observations: close to every ray (sideways) and to every
    /// LiDAR distance (along the ray), each by its own uncertainty. nil when the rays are all but
    /// parallel and there is no distance.
    public static func fuse(_ observations: [Observation]) -> simd_float3? {
        guard !observations.isEmpty else { return nil }
        var a = simd_float3x3(0)
        var b = simd_float3.zero
        let identity = matrix_identity_float3x3
        for o in observations {
            let u = o.direction
            let along = simd_float3x3(columns: (u * u.x, u * u.y, u * u.z))
            let across = identity - along
            let wl = 1 / (o.lateralSigma * o.lateralSigma)
            var m = across * wl
            var rhs = m * o.origin
            if let d = o.distance {
                let wd = 1 / (o.distanceSigma * o.distanceSigma)
                m += along * wd
                rhs += along * wd * o.origin + u * (wd * d)
            }
            a += m
            b += rhs
        }
        // Without a distance and with near-parallel rays, depth is undetermined.
        guard abs(a.determinant) > 1e-6 * pow(a[0][0] + a[1][1] + a[2][2], 3) else { return nil }
        let x = a.inverse * b
        return x.x.isFinite && x.y.isFinite && x.z.isFinite ? x : nil
    }

    /// How far `point` is from an observation's ray, sideways, in metres.
    public static func lateralError(_ point: simd_float3, _ o: Observation) -> Float {
        let v = point - o.origin
        let along = simd_dot(v, o.direction)
        return simd_length(v - o.direction * along)
    }

    /// The angle between two observations' rays, in degrees: triangulation needs a few degrees.
    public static func angle(_ a: Observation, _ b: Observation) -> Float {
        acos(max(-1, min(1, simd_dot(a.direction, b.direction)))) * 180 / .pi
    }
}
