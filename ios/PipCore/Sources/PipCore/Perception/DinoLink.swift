import Accelerate
import Foundation
import simd

/// Links two views of two sessions across a change of light: their parts are matched by what
/// they look like (Meta's DINOv2 patch tokens, `ViewFeatures`), each match lifted to its room at its
/// LiDAR depth, a turn and shift fitted to them (RANSAC), and that fit laid onto the surfaces
/// (DepthAlign: the walls and furniture, which light does not move) to the centimetre.
///
/// Measured on the user's sessions of 2 Nov (15:22 in daylight against 16:40 in low sun, where
/// described corners linked once): DINOv2 found 42 view links, most on the laptop, turned by the
/// user in between (20° against the room's 4°): points nearer than 0.8 m to the camera are left out
/// on both sides (what is held close may have moved; the room is further away). Then 13 view links,
/// laid to 0.5-0.8 cm, and the sessions linked (4 views over 3 m; the bathroom session of 15:31
/// against 16:40 too). Morning against night sessions of 1 Nov linked as well, a chain of two links
/// within 1° and 4 cm of the direct one; sessions of other rooms never linked.
public enum DinoLink {
    public struct Settings: Sendable {
        /// Patches more alike than this (cosine), each the other's best, with the next best clearly
        /// behind (ratio of the second best to the best).
        public var minSimilarity: Float = 0.5
        public var maxRatio: Float = 0.97
        public var minMatches = 12
        public var ransacIterations = 500
        /// RANSAC: a match agrees when it lands this close (metres; a patch is 14 px, 3 to 8 cm at
        /// 1-3 m), and this many must. In a bathroom with a mirror over the basin, a glass shower
        /// wall and a plain green wall (2 Nov, evening), the right stored views matched 15-53
        /// patches but only 2-10 agreed within 6 cm: the reflections have the wrong depth. At 8 cm
        /// and 6 the bathroom's own views linked (15-18° like the desk's), and no session of
        /// another room linked; the depth, the surfaces' hold and two agreeing views decide after.
        public var inlierDistance: Float = 0.08
        public var minInliers = 6
        /// The depth's verdict: this share of the surface within 1.5 cm of the other's, at this root
        /// mean square across it (2 Nov: the links found were laid to 0.3-0.8 cm).
        public var minOverlap: Float = 0.3
        public var maxRMS: Float = 0.01
        /// The surfaces must pin the fit down in every direction: the shift at the evidence to this,
        /// the turn to this (a wall and the floor alone leave the shift along the wall free: the
        /// link would be the appearance's alone, and a look-alike door could pass).
        public var maxShiftUncertainty: Float = 0.02
        public var maxTurnUncertainty: Float = 1.5 * .pi / 180
        /// The depth may correct the appearance's fit by at most this much (else it settled elsewhere).
        public var maxCorrectionTurn: Float = 12 * .pi / 180
        public var maxCorrectionShift: Float = 0.35
        /// The depth's fit must keep this many of the appearance's matches (within 6.4 cm): where it
        /// keeps fewer, the depth settled on another fit than the one the views were found by.
        /// Measured on 660 view links of three days' sessions (2 Nov): of 25 that disagreed with
        /// their sessions' link beyond its drift (23 more came from 3 snapshots stored with a wrong
        /// pose), 16 kept fewer than 3 matches; of 612 that agreed, 48 did.
        public var minKept = 3
        /// Points nearer than this to the camera are left out (see above).
        public var minDepth: Float = 0.8
        /// A match the depth confirmed counts as this many described corners in a session link
        /// (`SessionLink.consensus` asks 80 together): the surfaces laid to a centimetre are evidence
        /// the matches alone are not. Calibrated on 2 Nov: the day and low-sun sessions' hall views
        /// (22, 13 and 12 matches) link, a single view of 22 does not.
        public var evidenceWeight = 3
        public init() {}
    }

    /// A view prepared for linking: its features, its depth and each patch's room point (nil: no
    /// trustworthy depth, or nearer than `minDepth` to the camera).
    public struct View: Sendable {
        public var features: ViewFeatures.Described
        public var depth: DepthView
        public var points: [SIMD3<Float>?]

        public init(features: ViewFeatures.Described, depth: DepthView, minDepth: Float = Settings().minDepth) {
            self.features = features
            self.depth = depth
            let camera = depth.camera
            points = (0..<(ViewFeatures.columns * ViewFeatures.rows)).map { i in
                let c = ViewFeatures.Described.centre(of: i, width: depth.width, height: depth.height)
                guard let d = depth.trustedDepth(at: c) else { return nil }
                let w = depth.world(c, depth: d)
                return simd_distance(w, camera) >= minDepth ? w : nil
            }
        }
    }

    /// The patch pairs that are each other's best match, clearly.
    static func matches(_ a: View, _ b: View, settings: Settings) -> [(Int, Int)] {
        let ia = a.points.indices.filter { a.points[$0] != nil }, ib = b.points.indices.filter { b.points[$0] != nil }
        guard ia.count >= settings.minMatches, ib.count >= settings.minMatches else { return [] }
        let dim = ViewFeatures.dim
        var ma = [Float](repeating: 0, count: ia.count * dim), mb = [Float](repeating: 0, count: ib.count * dim)
        a.features.patches.withUnsafeBufferPointer { p in
            for (r, i) in ia.enumerated() { for k in 0..<dim { ma[r * dim + k] = p[i * dim + k] } }
        }
        b.features.patches.withUnsafeBufferPointer { p in
            for (r, i) in ib.enumerated() { for k in 0..<dim { mb[r * dim + k] = p[i * dim + k] } }
        }
        // Similarities: (ia × dim) · (ib × dim)ᵀ.
        var sim = [Float](repeating: 0, count: ia.count * ib.count)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(ia.count), Int32(ib.count), Int32(dim), 1, ma, Int32(dim), mb, Int32(dim), 0, &sim, Int32(ib.count))
        var bestOfB = [Int](repeating: -1, count: ib.count), bestOfBSim = [Float](repeating: -2, count: ib.count)
        for r in 0..<ia.count {
            for c in 0..<ib.count where sim[r * ib.count + c] > bestOfBSim[c] {
                bestOfBSim[c] = sim[r * ib.count + c]
                bestOfB[c] = r
            }
        }
        var out: [(Int, Int)] = []
        for r in 0..<ia.count {
            var best = -2 as Float, second = -2 as Float, at = -1
            for c in 0..<ib.count {
                let s = sim[r * ib.count + c]
                if s > best { second = best; best = s; at = c } else if s > second { second = s }
            }
            guard at >= 0, bestOfB[at] == r, best > settings.minSimilarity, second / max(best, 1e-6) < settings.maxRatio else { continue }
            out.append((ia[r], ib[at]))
        }
        return out
    }

    /// How far a pair of views got, for pipeval: patches with room points on each side, matches,
    /// RANSAC's agreeing matches, and the depth's overlap and fit.
    public struct Trace: Sendable {
        public var pointsA = 0, pointsB = 0, matches = 0, ransac = 0
        public var overlap: Float = 0, rms: Float = 0, correctionTurn: Float = 0, shiftUncertainty: Float = 0
        /// The appearance's matches its own fit keeps, and those the depth's fit keeps.
        public var close = 0, kept = 0
        /// The depth's fit, once laid.
        public var laid: UprightTransform?
        public var outcome = ""
        public init() {}
    }

    /// A view link from `a`'s room to `b`'s, or nil.
    public static func link(_ a: View, _ b: View, from: Int = 0, to: Int = 0, settings: Settings = Settings()) -> ViewLink? {
        var trace = Trace()
        return link(a, b, from: from, to: to, settings: settings, trace: &trace)
    }

    public static func link(_ a: View, _ b: View, from: Int = 0, to: Int = 0, settings: Settings = Settings(), trace: inout Trace) -> ViewLink? {
        trace.pointsA = a.points.compactMap { $0 }.count
        trace.pointsB = b.points.compactMap { $0 }.count
        let pairs = matches(a, b, settings: settings)
        trace.matches = pairs.count
        trace.outcome = "too few matches"
        guard pairs.count >= settings.minMatches else { return nil }
        let pa = pairs.map { a.points[$0.0]! }, pb = pairs.map { b.points[$0.1]! }
        var rng = SplitMix64(seed: UInt64(pa.count) &* 0x9E37_79B9 &+ UInt64(from) &* 31 &+ UInt64(to))
        var best: [Int] = []
        let tol = settings.inlierDistance
        for _ in 0..<settings.ransacIterations {
            let i = Int(rng.next() % UInt64(pa.count)), j = Int(rng.next() % UInt64(pa.count))
            guard i != j else { continue }
            let va = pa[j] - pa[i], vb = pb[j] - pb[i]
            let ha = simd_length(SIMD2(va.x, va.z)), hb = simd_length(SIMD2(vb.x, vb.z))
            guard ha > 0.05, abs(ha - hb) < tol, abs(va.y - vb.y) < tol else { continue }
            let m = UprightTransform.fit([pa[i], pa[j]], [pb[i], pb[j]])
            let inl = pa.indices.filter { simd_distance(m.apply(pa[$0]), pb[$0]) < tol }
            if inl.count > best.count { best = inl }
        }
        trace.ransac = best.count
        trace.outcome = "too few agree (RANSAC)"
        guard best.count >= settings.minInliers else { return nil }
        var fit = UprightTransform.fit(best.map { pa[$0] }, best.map { pb[$0] })
        let close = pa.indices.filter { simd_distance(fit.apply(pa[$0]), pb[$0]) < tol * 0.8 }
        trace.close = close.count
        guard close.count >= settings.minInliers else { return nil }
        fit = UprightTransform.fit(close.map { pa[$0] }, close.map { pb[$0] })
        // The surfaces decide.
        trace.outcome = "the depth could not lay it"
        guard let laid = DepthAlign.refine(a.depth, onto: b.depth, from: fit, minDepth: settings.minDepth) else { return nil }
        trace.overlap = laid.overlap
        trace.rms = laid.rms
        trace.laid = laid.transform
        trace.correctionTurn = laid.transform.turn(to: fit)
        trace.shiftUncertainty = laid.shiftUncertainty
        trace.outcome = "the depth disagreed"
        guard laid.overlap >= settings.minOverlap, laid.rms <= settings.maxRMS,
              laid.transform.turn(to: fit) <= settings.maxCorrectionTurn else { return nil }
        trace.outcome = "the surfaces leave it free"
        guard laid.shiftUncertainty <= settings.maxShiftUncertainty, laid.turnUncertainty <= settings.maxTurnUncertainty else { return nil }
        let centreA = close.map { pa[$0] }.reduce(.zero, +) / Float(close.count)
        guard laid.transform.distance(to: fit, at: centreA) <= settings.maxCorrectionShift else { return nil }
        // The appearance matches the depth's fit keeps, and where the evidence is: the surface laid.
        let agreeing = pa.indices.filter { simd_distance(laid.transform.apply(pa[$0]), pb[$0]) < tol * 0.8 }
        trace.kept = agreeing.count
        trace.outcome = "the depth kept too few matches"
        guard agreeing.count >= settings.minKept else { return nil }
        trace.outcome = "linked"
        let pts = laid.agreeing
        let centre = pts.reduce(.zero, +) / Float(pts.count)
        let spread = sqrt(pts.map { simd_distance_squared($0, centre) }.reduce(0, +) / Float(pts.count))
        let distances = pts.map { simd_distance($0, centre) }.sorted()
        let reach = distances[min(distances.count - 1, distances.count * 9 / 10)]
        return ViewLink(transform: laid.transform, inliers: agreeing.count * settings.evidenceWeight, residual: laid.rms, centre: centre, spread: spread, reach: reach,
                        from: from, to: to)
    }
}
