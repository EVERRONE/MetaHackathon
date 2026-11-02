import Foundation
import simd

/// Linking sessions: where a room point of one session is in another session's room.
///
/// Every session tracks in coordinates of its own (ARKit, started fresh). Two sessions that saw the
/// same things are linked by those things: a snapshot of each, matched by described corners
/// (FeatureMatcher), each match lifted to the room at its LiDAR depth in both sessions. Gravity is
/// shared (ARKit's rooms are upright), so the link is a turn about the vertical and a shift, fitted
/// with RANSAC. Distinctive print and edges pin it down; surfaces alone could not (31 Oct: laying
/// LiDAR surfaces onto each other linked 0 of 43 times: walls and floors slide along themselves).
///
/// Measured on the user's snapshots (1 Nov): sessions in similar light link to under a centimetre
/// near the matched views; a session's own coordinates drift (fits from different parts of one room
/// differed by up to 7° and 11 cm), so a link holds near its evidence: points are carried by the
/// links whose evidence is nearest. Weak fits can be wrong by metres: a session link is taken only
/// when independent views agree.

/// A turn about the vertical (y) and a shift: from one session's room coordinates to another's.
public struct UprightTransform: Codable, Sendable, Equatable, CustomStringConvertible {
    public var yaw: Float
    public var t: SIMD3<Float>

    public init(yaw: Float, t: SIMD3<Float>) {
        self.yaw = yaw
        self.t = t
    }

    public static let identity = UprightTransform(yaw: 0, t: .zero)

    public func apply(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let c = cos(yaw), s = sin(yaw)
        return SIMD3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z) + t
    }

    public var inverse: UprightTransform {
        let back = UprightTransform(yaw: -yaw, t: .zero)
        return UprightTransform(yaw: -yaw, t: -back.apply(t))
    }

    /// First `self`, then `next`.
    public func then(_ next: UprightTransform) -> UprightTransform {
        UprightTransform(yaw: Self.wrap(yaw + next.yaw), t: next.apply(t))
    }

    /// As a 4×4 matrix (column-major), to carry poses and anchors.
    public var matrix: simd_float4x4 {
        let c = cos(yaw), s = sin(yaw)
        return simd_float4x4(columns: (SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(t.x, t.y, t.z, 1)))
    }

    public var description: String { String(format: "turn %.1f°, shift (%.3f, %.3f, %.3f) m", yaw * 180 / .pi, t.x, t.y, t.z) }

    static func wrap(_ a: Float) -> Float {
        var a = a
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }

    /// Least squares from point pairs (b ≈ T a): the turn from the horizontal parts about their
    /// centroids, then the shift.
    public static func fit(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> UprightTransform {
        precondition(a.count == b.count && !a.isEmpty)
        let ca = a.reduce(.zero, +) / Float(a.count), cb = b.reduce(.zero, +) / Float(b.count)
        var cosSum: Float = 0, sinSum: Float = 0
        for (p, q) in zip(a, b) {
            let u = p - ca, v = q - cb
            cosSum += u.x * v.x + u.z * v.z
            sinSum += u.z * v.x - u.x * v.z
        }
        var r = UprightTransform(yaw: atan2(sinSum, cosSum), t: .zero)
        r.t = cb - r.apply(ca)
        return r
    }

    /// How far apart two transforms put a point (metres).
    public func distance(to other: UprightTransform, at p: SIMD3<Float>) -> Float {
        simd_distance(apply(p), other.apply(p))
    }

    /// The turn between two transforms (radians, absolute).
    public func turn(to other: UprightTransform) -> Float {
        abs(Self.wrap(yaw - other.yaw))
    }
}

/// A snapshot's described corners and, for each, its point in the session's room (nil without
/// trustworthy depth).
public struct ViewPoints: Sendable {
    public var features: [FeatureMatcher.Feature]
    public var world: [SIMD3<Float>?]
    /// Where the camera was (same coordinates): how far each point was from it.
    public var camera: SIMD3<Float>?

    public init(features: [FeatureMatcher.Feature], world: [SIMD3<Float>?], camera: SIMD3<Float>? = nil) {
        precondition(features.count == world.count)
        self.features = features
        self.world = world
        self.camera = camera
    }

    /// Described corners of `image`, lifted with `lift` (pixel → room point, or nil).
    public init(image: GrayImage, count: Int = 500, camera: SIMD3<Float>? = nil, lift: (SIMD2<Float>) -> SIMD3<Float>?) {
        let f = FeatureMatcher.features(in: image, count: count)
        self.init(features: f, world: f.map { lift($0.point) }, camera: camera)
    }

    /// The point of feature `i` if it is far enough from the camera to belong to the room.
    func roomPoint(_ i: Int, from minDepth: Float) -> SIMD3<Float>? {
        guard let p = world[i] else { return nil }
        if let camera, simd_distance(p, camera) < minDepth { return nil }
        return p
    }
}

/// Two snapshots of two sessions that saw the same things, and what that says.
public struct ViewLink: Sendable, Equatable {
    /// From the first session's room to the second's.
    public var transform: UprightTransform
    /// Matches that agree with it in 3D, and their median distance after it (metres).
    public var inliers: Int
    public var residual: Float
    /// Where the evidence is, in the first session's room (the agreeing points' centre), how far it
    /// spreads (the points' standard distance from that centre) and how far it reaches (the distance
    /// from the centre within which 90 % of them lie), metres.
    public var centre: SIMD3<Float>
    public var spread: Float
    public var reach: Float = 0
    /// Which snapshots (ids given by the caller).
    public var from: Int
    public var to: Int
}

public enum SessionLink {
    public struct Settings: Sendable {
        /// Described corners matched before a fit is tried.
        public var minMatches = 25
        /// A match agrees with a fit when it lands this close (metres; LiDAR is good to about 1 cm).
        public var inlierDistance: Float = 0.03
        public var ransacIterations = 400
        /// A view link: this many agreeing matches, this close, spread at least this far.
        public var minInliers = 20
        public var maxResidual: Float = 0.015
        /// (A close view of a keyboard spreads over 5-10 cm: its turn is less sure, but it carries
        /// the points near it well, which is what it is used for.)
        public var minSpread: Float = 0.05
        /// Points nearer the camera than this are left out: what is held or carried (a laptop on the
        /// lap, a remote in the hand) moves between sessions, and matches perfectly with itself. On
        /// 1 Nov the laptop, on the desk at 15:08 and on the lap at 17:01, gave six view links that
        /// agreed to a few degrees: about the laptop, not the room.
        public var minDepth: Float = 0.8
        /// A session link: its agreeing evidence must span this much of the room (a moved object
        /// gives evidence in one spot; a room gives it all round).
        public var minExtent: Float = 1.0
        /// Two view links agree when they carry the points between their evidence within this.
        public var agreeDistance: Float = 0.04
        public var agreeTurn: Float = 2 * .pi / 180
        /// A session link: independent views that agree, and their agreeing matches together.
        public var minViews = 2
        public var minTotalInliers = 80
        /// A session's own drift: view links from other parts of the room may differ from the
        /// agreeing core by this much and still hold near their evidence (1 Nov: 11 cm and 7°
        /// between two parts of one session). Beyond it a view link is a look-alike, never used.
        public var driftDistance: Float = 0.2
        public var driftTurn: Float = 10 * .pi / 180
        /// The drift grows with the way walked between the evidence: this much more per metre between
        /// a view link's evidence and the core's (2 Nov: day and low-sun links of one pair of sessions
        /// differed by 30 cm at the desk, 5 m from the hall views of the core; each held near its own).
        public var driftPerMetre: Float = 0.06
        public init() {}
    }

    /// Matches two views and fits the turn and shift from the first's room to the second's.
    public static func link(_ a: ViewPoints, _ b: ViewPoints, from: Int = 0, to: Int = 0, settings: Settings = Settings()) -> ViewLink? {
        let pairs = FeatureMatcher.match(a.features, b.features)
        guard pairs.count >= settings.minMatches else { return nil }
        var pa: [SIMD3<Float>] = [], pb: [SIMD3<Float>] = []
        for (i, j) in pairs {
            guard let p = a.roomPoint(i, from: settings.minDepth), let q = b.roomPoint(j, from: settings.minDepth) else { continue }
            pa.append(p)
            pb.append(q)
        }
        guard pa.count >= settings.minInliers else { return nil }
        var rng = SplitMix64(seed: UInt64(pa.count) &* 0x9E37_79B9 &+ UInt64(from) &* 31 &+ UInt64(to))
        var best: [Int] = []
        for _ in 0..<settings.ransacIterations {
            let i = Int(rng.next() % UInt64(pa.count)), j = Int(rng.next() % UInt64(pa.count))
            guard i != j else { continue }
            // Two pairs fix the turn and the shift; they must be a rigid pair (same length, same rise).
            let va = pa[j] - pa[i], vb = pb[j] - pb[i]
            let ha = simd_length(SIMD2(va.x, va.z)), hb = simd_length(SIMD2(vb.x, vb.z))
            guard ha > 0.05, abs(ha - hb) < settings.inlierDistance, abs(va.y - vb.y) < settings.inlierDistance else { continue }
            let m = UprightTransform.fit([pa[i], pa[j]], [pb[i], pb[j]])
            let inl = pa.indices.filter { simd_distance(m.apply(pa[$0]), pb[$0]) < settings.inlierDistance * 1.3 }
            if inl.count > best.count { best = inl }
        }
        guard best.count >= settings.minInliers / 2 else { return nil }
        var m = UprightTransform.fit(best.map { pa[$0] }, best.map { pb[$0] })
        for _ in 0..<2 {
            let inl = pa.indices.filter { simd_distance(m.apply(pa[$0]), pb[$0]) < settings.inlierDistance }
            guard inl.count >= 3 else { return nil }
            m = UprightTransform.fit(inl.map { pa[$0] }, inl.map { pb[$0] })
            best = inl
        }
        let residuals = best.map { simd_distance(m.apply(pa[$0]), pb[$0]) }.sorted()
        let pts = best.map { pa[$0] }
        let centre = pts.reduce(.zero, +) / Float(pts.count)
        let spread = sqrt(pts.map { simd_distance_squared($0, centre) }.reduce(0, +) / Float(pts.count))
        let distances = pts.map { simd_distance($0, centre) }.sorted()
        let reach = distances[min(distances.count - 1, distances.count * 9 / 10)]
        let link = ViewLink(transform: m, inliers: best.count, residual: residuals[residuals.count / 2], centre: centre, spread: spread, reach: reach, from: from, to: to)
        guard link.inliers >= settings.minInliers, link.residual <= settings.maxResidual, link.spread >= settings.minSpread else { return nil }
        return link
    }

    /// Whether two view links say the same: each carries the other's evidence where it does.
    public static func agree(_ x: ViewLink, _ y: ViewLink, settings: Settings = Settings()) -> Bool {
        guard x.transform.turn(to: y.transform) <= settings.agreeTurn else { return false }
        let mid = (x.centre + y.centre) / 2
        return x.transform.distance(to: y.transform, at: x.centre) <= settings.agreeDistance
            && x.transform.distance(to: y.transform, at: y.centre) <= settings.agreeDistance
            && x.transform.distance(to: y.transform, at: mid) <= settings.agreeDistance
    }

    /// The view links that agree with the most others (by agreeing matches), if they make a session
    /// link: views of at least `minViews` different snapshots on the second side, with enough
    /// agreeing matches together. Conflicting groups (a look-alike room) are left out.
    public static func consensus(_ links: [ViewLink], settings: Settings = Settings()) -> [ViewLink]? {
        guard !links.isEmpty else { return nil }
        var best: [ViewLink] = []
        var bestScore = 0
        for seed in links {
            let group = links.filter { agree(seed, $0, settings: settings) }
            let score = group.reduce(0) { $0 + $1.inliers }
            if score > bestScore { best = group; bestScore = score }
        }
        let views = Set(best.map(\.to)).count
        guard views >= settings.minViews, bestScore >= settings.minTotalInliers, extent(best) >= settings.minExtent else { return nil }
        return best
    }

    /// How much of the room view links' evidence spans: the widest distance between their evidence,
    /// each reaching as far as 90 % of its points (its `reach`; links made before reach was kept: 1.6
    /// times their spread, about that for points spread evenly). The standard distance alone said
    /// 0.7 m for a 1.2 m table, and a whole session was refused (1 Nov, the statues).
    public static func extent(_ links: [ViewLink]) -> Float {
        func reach(_ l: ViewLink) -> Float { l.reach > 0 ? l.reach : 1.6 * l.spread }
        var widest: Float = 0
        for x in links {
            widest = max(widest, 2 * reach(x))
            for y in links { widest = max(widest, simd_distance(x.centre, y.centre) + reach(x) + reach(y)) }
        }
        return widest
    }

    /// The view links that may carry points: the agreeing core, and those that differ from it only by
    /// the sessions' drift (at their own evidence, they land within `driftDistance` of where the
    /// core puts it, and turn within `driftTurn`).
    public static func usable(_ links: [ViewLink], core: [ViewLink], settings: Settings = Settings()) -> [ViewLink] {
        links.filter { l in
            core.contains(l) || core.contains { c in
                c.transform.turn(to: l.transform) <= settings.driftTurn
                    && c.transform.distance(to: l.transform, at: l.centre) <= settings.driftDistance + settings.driftPerMetre * simd_distance(l.centre, c.centre)
            }
        }
    }

    /// Carries a point of the first session's room into the second's by the links whose evidence is
    /// nearest (each session drifts: a link holds best near its evidence), weighted by closeness and
    /// agreeing matches.
    public static func carry(_ p: SIMD3<Float>, by links: [ViewLink]) -> SIMD3<Float>? {
        guard !links.isEmpty else { return nil }
        let near = links.sorted { simd_distance($0.centre, p) < simd_distance($1.centre, p) }.prefix(3)
        var sum = SIMD3<Float>.zero, weights: Float = 0
        for l in near {
            let w = Float(l.inliers) / (0.25 + simd_distance(l.centre, p))
            sum += l.transform.apply(p) * w
            weights += w
        }
        return sum / weights
    }

    /// The link nearest a point (to carry poses and directions).
    public static func nearest(_ p: SIMD3<Float>, in links: [ViewLink]) -> ViewLink? {
        links.min { simd_distance($0.centre, p) < simd_distance($1.centre, p) }
    }
}
