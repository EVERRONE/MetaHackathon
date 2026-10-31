import simd

/// Lays one 3D view of a room onto another: the live depth points onto a stored map piece.
///
/// ARKit's world is always upright (gravity is its y axis), in every session. Two map pieces of
/// the same house therefore differ only by a turn about the vertical and a shift: four numbers,
/// not six. The fit matches each live point to the nearest stored surface and moves along the
/// surfaces' normals (point-to-plane, which converges in a few rounds on walls and floors), from
/// coarse to fine. It also measures how firmly the visible surfaces pin down each of the four
/// numbers: a bare wall or an empty corridor leaves a shift along it free, and then Pip does not
/// link the pieces at all.
public enum PointRegistration {
    public struct Result: Sendable {
        /// Maps points of the source piece into the target piece.
        public var transform: simd_float4x4
        /// Turn about the vertical, in degrees, and shift, in metres.
        public var yawDegrees: Float
        public var translation: simd_float3
        /// Root mean square distance of the matched points, in metres.
        public var rms: Float
        /// Share of source points within `inlierDistance` of the target after the fit.
        public var inlierRatio: Float
        /// How firmly the weakest of the four numbers is pinned down: the share of matched
        /// points whose surface constrains it (0 for a bare wall).
        public var constraint: Float
        public var wellConstrained: Bool { constraint >= PointRegistration.minConstraint }
        /// Whether this fit is good enough to link two map pieces.
        public var isMatch: Bool { wellConstrained && rms < 0.025 && inlierRatio > 0.6 }
    }

    public static let inlierDistance: Float = 0.03
    public static let minConstraint: Float = 0.04

    /// A turn about the vertical axis by `yaw` radians and a shift.
    public static func transform(yaw: Float, translation t: simd_float3) -> simd_float4x4 {
        let c = cos(yaw), s = sin(yaw)
        return simd_float4x4(columns: (simd_float4(c, 0, -s, 0), simd_float4(0, 1, 0, 0), simd_float4(s, 0, c, 0), simd_float4(t, 1)))
    }

    /// The yaw of a rotation about the vertical (an upright camera pose has its heading here).
    public static func yaw(of m: simd_float4x4) -> Float {
        atan2(m.columns.2.x, m.columns.2.z)
    }

    /// The best turn about the vertical and shift for matched point pairs (closed form).
    static func solve(_ pairs: [(simd_float3, simd_float3)]) -> (yaw: Float, translation: simd_float3)? {
        guard pairs.count >= 3 else { return nil }
        let n = Float(pairs.count)
        let cs = pairs.reduce(simd_float3.zero) { $0 + $1.0 } / n
        let ct = pairs.reduce(simd_float3.zero) { $0 + $1.1 } / n
        var sinSum: Float = 0, cosSum: Float = 0
        for (s, t) in pairs {
            let a = s - cs, b = t - ct
            cosSum += a.x * b.x + a.z * b.z
            sinSum += b.x * a.z - b.z * a.x
        }
        let yaw = atan2(sinSum, cosSum)
        return (yaw, ct - (transform(yaw: yaw, translation: .zero) * simd_float4(cs, 1)).xyz)
    }

    /// Fits `source` onto `target`, starting from `initial` (source → target), within about half a
    /// metre and 25 degrees of the truth. nil when too few points ever match.
    public static func align(source: [simd_float3], target: RegistrationTarget, initial: simd_float4x4, iterations: Int = 30) -> Result? {
        guard source.count >= 50 else { return nil }
        var yaw = yaw(of: initial)
        var t = initial.columns.3.xyz
        let schedule: [Float] = [0.5, 0.35, 0.25, 0.15, 0.1, 0.07, 0.05, 0.04]
        var information = simd_double4x4(0)
        var matched = 0
        for i in 0..<iterations {
            let reach = schedule[min(i * schedule.count / max(1, iterations - 6), schedule.count - 1)]
            let m = transform(yaw: yaw, translation: t)
            let index = target.index(for: reach)
            var moved: [(p: simd_float3, q: simd_float3, n: simd_float3, weight: Float)] = []
            moved.reserveCapacity(source.count)
            for s in source {
                let p = (m * simd_float4(s, 1)).xyz
                if let k = index.nearestIndex(to: p, within: reach) { moved.append((p, target.points[k], target.normals[k], target.weights[k])) }
            }
            guard moved.count >= 20 else { return nil }
            // Linearised about the matched points' centre: a small turn δ moves v by δ·(v.z, 0, −v.x).
            let c = moved.reduce(simd_float3.zero) { $0 + $1.p } / Float(moved.count)
            var a = simd_double4x4(0)
            var b = simd_double4(0, 0, 0, 0)
            var fixed = simd_double4x4(0)
            for (p, q, n, weight) in moved {
                let v = p - c
                let row = simd_double4(Double(simd_dot(n, simd_float3(v.z, 0, -v.x))), Double(n.x), Double(n.y), Double(n.z))
                let r = Double(simd_dot(n, p - q))
                // Matches far off count less (a robust fit), and so does furniture.
                let w = (abs(r) < Double(reach) / 2 ? 1 : Double(reach) / 2 / abs(r)) * Double(weight)
                let outer = simd_double4x4(columns: (row * (w * row.x), row * (w * row.y), row * (w * row.z), row * (w * row.w)))
                a += outer
                if weight >= 1 { fixed += outer }
                b -= row * (w * r)
            }
            // Only fixed structure counts for "unambiguous": furniture may have moved.
            information = fixed
            matched = moved.count
            // A little damping keeps a free direction (a bare wall) from running off.
            let damping = 1e-4 * (a[0][0] + a[1][1] + a[2][2] + a[3][3])
            let x = (a + simd_double4x4(diagonal: simd_double4(repeating: damping))).inverse * b
            guard x.x.isFinite, x.y.isFinite, x.z.isFinite, x.w.isFinite else { return nil }
            let delta = Float(x.x)
            let step = simd_float3(Float(x.y), Float(x.z), Float(x.w))
            // New transform: turn by δ about c, then shift.
            let r = transform(yaw: delta, translation: .zero)
            t = (r * simd_float4(t - c, 1)).xyz + c + step
            yaw += delta
            if abs(delta) < 1e-5, simd_length(step) < 1e-4, reach <= 0.05 { break }
        }
        let final = transform(yaw: yaw, translation: t)
        let (rms, ratio) = score(source, target, final)
        let eigen = SymmetricEigen.values(information)
        let constraint = matched > 0 ? Float((eigen.min() ?? 0) / Double(matched)) : 0
        return Result(transform: final, yawDegrees: yaw * 180 / .pi, translation: t, rms: rms, inlierRatio: ratio, constraint: max(0, constraint))
    }

    static func score(_ source: [simd_float3], _ target: RegistrationTarget, _ m: simd_float4x4) -> (rms: Float, ratio: Float) {
        var sum: Float = 0
        var count = 0
        let index = target.index(for: inlierDistance)
        for s in source {
            let q = (m * simd_float4(s, 1)).xyz
            if let k = index.nearestIndex(to: q, within: inlierDistance) {
                sum += simd_distance_squared(target.points[k], q)
                count += 1
            }
        }
        return (count > 0 ? sqrt(sum / Float(count)) : .infinity, Float(count) / Float(source.count))
    }
}

/// A stored map piece: its points with their surface normals, indexed at three cell sizes so both
/// the coarse first rounds of a fit (half a metre) and the fine last ones look at few cells.
public struct RegistrationTarget: Sendable {
    public let points: [simd_float3]
    public let normals: [simd_float3]
    /// How much each point counts in a fit: fixed structure (walls, floor, doors) fully, furniture
    /// that may have moved since (seats, unclassified things) less.
    public let weights: [Float]
    let levels: [VoxelIndex]
    public var count: Int { points.count }

    /// `normals` from the mesh when known (else estimated from neighbours), `weights` per point.
    public init(points: [simd_float3], normals given: [simd_float3]? = nil, weights: [Float]? = nil) {
        self.points = points
        levels = [0.25, 0.1, 0.04].map { VoxelIndex(points: points, cell: $0) }
        if let given, given.count == points.count {
            normals = given.map { simd_length($0) > 0.5 ? simd_normalize($0) : simd_float3(0, 1, 0) }
        } else {
            // Each point's normal from its neighbours within 8 cm (the smallest spread direction).
            let near = levels[1]
            normals = points.map { p in
                let neighbours = near.indices(near: p, within: 0.08).map { points[$0] }
                return Self.normal(of: neighbours) ?? simd_float3(0, 1, 0)
            }
        }
        self.weights = weights.flatMap { $0.count == points.count ? $0 : nil } ?? Array(repeating: 1, count: points.count)
    }

    /// The finest index whose cells are at least half the search reach.
    func index(for reach: Float) -> VoxelIndex {
        levels.last { $0.cell >= reach / 2 } ?? levels[0]
    }

    static func normal(of pts: [simd_float3]) -> simd_float3? {
        guard pts.count >= 4 else { return nil }
        let c = pts.reduce(simd_float3.zero, +) / Float(pts.count)
        var cov = simd_float3x3(0)
        for p in pts {
            let d = p - c
            cov += simd_float3x3(columns: (d * d.x, d * d.y, d * d.z))
        }
        let shift = cov[0][0] + cov[1][1] + cov[2][2]
        let b = simd_float3x3(diagonal: simd_float3(repeating: shift)) - cov
        var v = simd_normalize(simd_float3(0.3, 0.5, 0.8))
        for _ in 0..<40 { v = simd_normalize(b * v) }
        return v.x.isFinite ? v : nil
    }
}

/// Nearest-point lookup in a point cloud through a grid of cells.
public struct VoxelIndex: Sendable {
    public let cell: Float
    private let points: [simd_float3]
    private var buckets: [SIMD3<Int32>: [Int32]] = [:]
    public var count: Int { points.count }

    public init(points: [simd_float3], cell: Float = 0.1) {
        self.cell = cell
        self.points = points
        for (i, p) in points.enumerated() { buckets[Self.key(p, cell), default: []].append(Int32(i)) }
    }

    static func key(_ p: simd_float3, _ cell: Float) -> SIMD3<Int32> {
        SIMD3(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)), Int32((p.z / cell).rounded(.down)))
    }

    private func cells(around p: simd_float3, within radius: Float) -> [Int32] {
        let k = Self.key(p, cell)
        let r = Int32(max(1, (radius / cell).rounded(.up)))
        var out: [Int32] = []
        for dx in -r...r {
            for dy in -r...r {
                for dz in -r...r {
                    if let bucket = buckets[k &+ SIMD3(dx, dy, dz)] { out.append(contentsOf: bucket) }
                }
            }
        }
        return out
    }

    /// The index of the nearest point within `radius`, or nil.
    public func nearestIndex(to p: simd_float3, within radius: Float) -> Int? {
        var best: Int?
        var bestD = radius * radius
        for i in cells(around: p, within: radius) {
            let d = simd_distance_squared(p, points[Int(i)])
            if d <= bestD {
                bestD = d
                best = Int(i)
            }
        }
        return best
    }

    public func nearest(to p: simd_float3, within radius: Float) -> simd_float3? {
        nearestIndex(to: p, within: radius).map { points[$0] }
    }

    /// Every point within `radius`.
    public func indices(near p: simd_float3, within radius: Float) -> [Int] {
        cells(around: p, within: radius).map(Int.init).filter { simd_distance_squared(p, points[$0]) <= radius * radius }
    }

    /// One point per `size` cube: an even, smaller cloud.
    public static func downsample(_ points: [simd_float3], size: Float) -> [simd_float3] {
        var seen = Set<SIMD3<Int32>>()
        var out: [simd_float3] = []
        for p in points where seen.insert(key(p, size)).inserted { out.append(p) }
        return out
    }

    /// One point per `size` cube, the average of every measurement in it (less noise than any
    /// single one), with the average normal and the most common surface class.
    public static func average(_ points: [simd_float3], normals: [simd_float3], classes: [UInt8], size: Float) -> (points: [simd_float3], normals: [simd_float3], classes: [UInt8]) {
        struct Acc { var p = simd_float3.zero; var n = simd_float3.zero; var count: Float = 0; var votes = [UInt8: Int]() }
        var cells: [SIMD3<Int32>: Acc] = [:]
        let hasNormals = normals.count == points.count, hasClasses = classes.count == points.count
        for i in points.indices {
            var a = cells[key(points[i], size), default: Acc()]
            a.p += points[i]
            if hasNormals { a.n += normals[i] }
            a.count += 1
            if hasClasses { a.votes[classes[i], default: 0] += 1 }
            cells[key(points[i], size)] = a
        }
        var p: [simd_float3] = [], n: [simd_float3] = [], c: [UInt8] = []
        p.reserveCapacity(cells.count)
        for a in cells.values {
            p.append(a.p / a.count)
            n.append(simd_length(a.n) > 1e-6 ? simd_normalize(a.n) : .zero)
            c.append(a.votes.max { $0.value < $1.value }?.key ?? 0)
        }
        return (p, n, c)
    }
}

/// Eigenvalues of a symmetric 4×4 matrix (Jacobi rotations).
enum SymmetricEigen {
    static func values(_ m: simd_double4x4) -> [Double] {
        var a = (0..<4).map { i in (0..<4).map { j in m[j][i] } }
        for _ in 0..<50 {
            var p = 0, q = 1
            var largest = 0.0
            for i in 0..<4 { for j in (i + 1)..<4 where abs(a[i][j]) > largest { largest = abs(a[i][j]); p = i; q = j } }
            if largest < 1e-12 { break }
            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = (theta >= 0 ? 1 : -1) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot(), s = t * c
            for k in 0..<4 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
            }
            for k in 0..<4 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
        }
        return (0..<4).map { a[$0][$0] }
    }
}

extension simd_float4 {
    var xyz: simd_float3 { simd_float3(x, y, z) }
}
