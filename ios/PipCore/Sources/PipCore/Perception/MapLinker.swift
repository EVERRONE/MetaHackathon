import simd

/// The geometry of linking a live session to a stored map piece, to the centimetre.
///
/// 1. `seed`: a stored keyframe that looked like the live view gives a rough start (the camera
///    stood about there; both worlds are upright, so only the headings differ).
/// 2. `PointRegistration.align` from that start, twice from different spots (`LinkConsensus`):
///    is this the same place, unambiguously?
/// 3. `refine`: one fine fit over everything both sessions saw (the live LiDAR mesh around the
///    user), with the uncertainty of the result. `Refined.uncertainty(at:)` says how far off a
///    stored place can be once it is brought over: Pip shows it only when that is under 1.5 cm.
public enum MapLinker {
    /// The direction a camera looks, as a turn about the vertical (radians; camera looks down −Z).
    public static func heading(_ pose: simd_float4x4) -> Float {
        let forward = -pose.columns.2.xyz
        return atan2(forward.x, forward.z)
    }

    /// Live frame → stored frame, assuming the camera stands where it stood for the stored view.
    public static func seed(live: simd_float4x4, stored: simd_float4x4) -> simd_float4x4 {
        let yaw = heading(stored) - heading(live)
        let r = PointRegistration.transform(yaw: yaw, translation: .zero)
        let t = stored.columns.3.xyz - (r * simd_float4(live.columns.3.xyz, 1)).xyz
        return PointRegistration.transform(yaw: yaw, translation: t)
    }

    /// Starts around a look-alike keyframe: the user may stand up to ~1.5 m nearer or further
    /// along the view and look up to ~50° to either side (one fit converges from about 20° and
    /// 0.6 m, measured), so five headings at three distances.
    public static func seeds(live: simd_float4x4, stored: simd_float4x4) -> [simd_float4x4] {
        let forward = simd_normalize(simd_float3(-stored.columns.2.x, 0, -stored.columns.2.z))
        var out: [simd_float4x4] = []
        for along: Float in [0, -0.8, 0.8] {
            var at = stored
            at.columns.3 = simd_float4(stored.columns.3.xyz + forward * along, 1)
            for turn: Float in [0, 20, -20, 40, -40] {
                let base = seed(live: live, stored: at)
                // Turning the start about the stored camera's position.
                let c = at.columns.3.xyz
                let r = PointRegistration.transform(yaw: turn * .pi / 180, translation: .zero)
                let t = (r * simd_float4(base.columns.3.xyz - c, 1)).xyz + c
                out.append(PointRegistration.transform(yaw: PointRegistration.yaw(of: base) + turn * .pi / 180, translation: t))
            }
        }
        return out
    }

    /// The most promising starts: the share of live points that land near a stored surface.
    public static func bestSeeds(_ seeds: [simd_float4x4], source: [simd_float3], target: RegistrationTarget, keep: Int) -> [simd_float4x4] {
        let index = target.index(for: 0.15)
        let scored = seeds.map { m -> (simd_float4x4, Int) in
            (m, source.reduce(0) { n, s in index.nearestIndex(to: (m * simd_float4(s, 1)).xyz, within: 0.15) == nil ? n : n + 1 })
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(keep).map(\.0)
    }

    public struct Refined: Sendable {
        /// Live frame → stored frame.
        public var transform: simd_float4x4
        public var rms: Float
        public var inlierRatio: Float
        /// Covariance of (turn about `centre`, shift x, y, z), in radians² and metres².
        public var covariance: simd_double4x4
        /// Where the turn's uncertainty is centred (stored frame): the middle of the overlap.
        public var centre: simd_float3
        public var matched: Int
        /// As in `PointRegistration.Result`: how firmly the weakest direction is pinned down.
        public var constraint: Float = 0

        /// How far off (one standard deviation, metres) a point of the stored frame can land in
        /// the live frame: the fit's own uncertainty (shift, and turn growing with distance from
        /// the overlap), plus what no fit averages away: a floor for LiDAR bias and gravity, and
        /// tracking drift that grows with distance from where the two sessions overlapped.
        public func uncertainty(at p: simd_float3) -> Float {
            let v = p - centre
            // Displacement of p = J · (δturn, δx, δy, δz).
            let rows = [simd_double4(Double(v.z), 1, 0, 0), simd_double4(0, 0, 1, 0), simd_double4(Double(-v.x), 0, 0, 1)]
            let fit = rows.reduce(0.0) { $0 + simd_dot($1, covariance * $1) }
            let horizontal = Double(simd_length(simd_float2(v.x, v.z)))
            let floor = MapLinker.floorSigma * MapLinker.floorSigma
            let turn = pow(MapLinker.turnFloor * horizontal, 2)
            let drift = pow(MapLinker.driftPerMetre * max(0, horizontal - MapLinker.overlapRadius), 2)
            return Float((max(0, fit) + floor + turn + drift).squareRoot())
        }
    }

    /// Mesh points next to each other are not independent measurements (the mesh is smoothed,
    /// LiDAR errors are correlated): the uncertainty counts one in this many.
    static let correlation: Double = 10
    /// Errors no fit averages away, set conservatively: 5 mm for LiDAR bias on some materials and
    /// mesh smoothing, 0.15° of turn (gravity and heading between sessions), and 0.5 % tracking
    /// drift per metre beyond 2 m from the overlap (ARKit's typical visual-inertial drift).
    public static let floorSigma: Double = 0.005
    public static let turnFloor: Double = 0.15 * .pi / 180
    public static let driftPerMetre: Double = 0.005
    public static let overlapRadius: Double = 2
    /// A place is shown only when it lands within this (one standard deviation).
    public static let showWithin: Float = 0.015

    /// The fine fit over the whole overlap, from a linked start (within a few centimetres).
    public static func refine(source: [simd_float3], target: RegistrationTarget, initial: simd_float4x4, iterations: Int = 15) -> Refined? {
        guard source.count >= 100 else { return nil }
        var yaw = PointRegistration.yaw(of: initial)
        var t = initial.columns.3.xyz
        var information = simd_double4x4(0)
        var centre = simd_float3.zero
        var residuals: [Float] = []
        let index = target.index(for: 0.06)
        for i in 0..<iterations {
            let reach: Float = i < iterations / 2 ? 0.06 : 0.04
            let m = PointRegistration.transform(yaw: yaw, translation: t)
            var pairs: [(p: simd_float3, q: simd_float3, n: simd_float3)] = []
            pairs.reserveCapacity(source.count)
            for s in source {
                let p = (m * simd_float4(s, 1)).xyz
                if let k = index.nearestIndex(to: p, within: reach) { pairs.append((p, target.points[k], target.normals[k])) }
            }
            guard pairs.count >= 60 else { return nil }
            centre = pairs.reduce(simd_float3.zero) { $0 + $1.p } / Float(pairs.count)
            var a = simd_double4x4(0)
            var b = simd_double4(0, 0, 0, 0)
            residuals = []
            for (p, q, n) in pairs {
                let v = p - centre
                let row = simd_double4(Double(simd_dot(n, simd_float3(v.z, 0, -v.x))), Double(n.x), Double(n.y), Double(n.z))
                let r = Double(simd_dot(n, p - q))
                residuals.append(Float(r))
                // Tukey-like: matches over 2 cm off the surface hardly count.
                let w = abs(r) < 0.02 ? 1 : 0.02 / abs(r)
                a += simd_double4x4(columns: (row * (w * row.x), row * (w * row.y), row * (w * row.z), row * (w * row.w)))
                b -= row * (w * r)
            }
            information = a
            let damping = 1e-6 * (a[0][0] + a[1][1] + a[2][2] + a[3][3])
            let x = (a + simd_double4x4(diagonal: simd_double4(repeating: damping))).inverse * b
            guard x.x.isFinite, x.y.isFinite, x.z.isFinite, x.w.isFinite else { return nil }
            let r = PointRegistration.transform(yaw: Float(x.x), translation: .zero)
            t = (r * simd_float4(t - centre, 1)).xyz + centre + simd_float3(Float(x.y), Float(x.z), Float(x.w))
            yaw += Float(x.x)
            if abs(x.x) < 1e-6, simd_length(simd_double3(x.y, x.z, x.w)) < 1e-5 { break }
        }
        let final = PointRegistration.transform(yaw: yaw, translation: t)
        let (rms, ratio) = PointRegistration.score(source, target, final)
        // Residual spread along the normals, the measurement noise of this fit.
        let sigma2 = Double(residuals.reduce(0) { $0 + $1 * $1 }) / Double(max(1, residuals.count))
        let covariance = information.inverse * (sigma2 * correlation)
        let constraint = Float((SymmetricEigen.values(information).min() ?? 0) / Double(max(1, residuals.count)))
        return Refined(transform: final, rms: rms, inlierRatio: ratio, covariance: covariance, centre: centre, matched: residuals.count, constraint: max(0, constraint))
    }
}
