import CoreGraphics
import Foundation
import ImageIO
import PipCore
import simd

// pipeval relocalise <memory/frames folder> <piece A prefix> <piece B prefix>
//
// Where session B is in session A's room, from their stored snapshots alone (no ARKit map): each
// pair of snapshots that see the same things is matched by described corners (FeatureMatcher),
// each match is lifted to the room at its LiDAR depth in both sessions, and the turn about the
// vertical and the shift that lay A's points onto B's are fitted (gravity is shared, so four
// unknowns), with RANSAC. If the pairs agree on one turn and shift, B's position in A's room is
// known. Prints every pair's fit and how the fits agree.

struct StoredFrame: Decodable {
    var id: String
    var time: Double
    var width: Int
    var height: Int
    var sensorWidth: Double
    var sensorHeight: Double
    var intrinsics: [Float]
    var pose: [Float]
    var piece: String?
    var depthW: Int
    var depthH: Int

    var transform: simd_float4x4 {
        simd_float4x4(columns: (SIMD4(pose[0], pose[1], pose[2], pose[3]), SIMD4(pose[4], pose[5], pose[6], pose[7]),
                                SIMD4(pose[8], pose[9], pose[10], pose[11]), SIMD4(pose[12], pose[13], pose[14], pose[15])))
    }

    /// A stored pixel (upright) at a depth, in the session's room coordinates (as Keyframes.Frame).
    func world(_ p: SIMD2<Float>, depth d: Float) -> SIMD3<Float> {
        let s = Float(sensorWidth) / Float(height)
        let qx = p.y * s, qy = Float(sensorHeight) - p.x * s
        let fx = intrinsics[0], fy = intrinsics[4], cx = intrinsics[6], cy = intrinsics[7]
        let x = (qx - cx) / fx * d, y = -(qy - cy) / fy * d
        let w = transform * SIMD4(x, y, -d, 1)
        return SIMD3(w.x, w.y, w.z)
    }
}

/// B = R_y(yaw) A + t: a turn about the vertical and a shift.
struct Upright: CustomStringConvertible {
    var yaw: Float
    var t: SIMD3<Float>
    func apply(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let c = cos(yaw), s = sin(yaw)
        return SIMD3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z) + t
    }
    var description: String { String(format: "turn %6.1f°, shift (%6.3f, %6.3f, %6.3f) m", yaw * 180 / .pi, t.x, t.y, t.z) }

    /// Least squares from pairs: the turn from the horizontal parts about their centroids, then the shift.
    static func fit(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Upright {
        let ca = a.reduce(.zero, +) / Float(a.count), cb = b.reduce(.zero, +) / Float(b.count)
        var sxx: Float = 0, sxz: Float = 0
        for (p, q) in zip(a, b) {
            let u = p - ca, v = q - cb
            // R_y(θ) u ≈ v on (x, z): maximise Σ v·R u.
            sxx += u.x * v.x + u.z * v.z
            sxz += u.z * v.x - u.x * v.z
        }
        let yaw = atan2(sxz, sxx)
        var r = Upright(yaw: yaw, t: .zero)
        r.t = cb - r.apply(ca)
        return r
    }
}

func relocalise(_ args: [String]) {
    guard args.count >= 4 else { fail("pipeval relocalise <memory/frames> <piece A> <piece B> [--min 25]") }
    let dir = URL(fileURLWithPath: args[1])
    guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent("index.json").path),
          let all = try? JSONDecoder().decode([StoredFrame].self, from: data) else { fail("cannot read index.json") }
    let minMatches = args.firstIndex(of: "--min").flatMap { Int(args[$0 + 1]) } ?? 25
    let a = all.filter { $0.piece?.hasPrefix(args[2]) == true }, b = all.filter { $0.piece?.hasPrefix(args[3]) == true }
    print("piece A \(args[2]): \(a.count) snapshots; piece B \(args[3]): \(b.count)")

    struct Loaded { var frame: StoredFrame; var features: [FeatureMatcher.Feature]; var depth: [Float] }
    func load(_ f: StoredFrame) -> Loaded? {
        guard let jpeg = FileManager.default.contents(atPath: dir.appendingPathComponent("\(f.id).jpg").path),
              let image = SetOfMarks.load(jpeg, maxSide: 4096), let grey = GrayImage(image),
              let raw = FileManager.default.contents(atPath: dir.appendingPathComponent("\(f.id).depth").path),
              raw.count == f.depthW * f.depthH * 2 else { return nil }
        let depth = raw.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }.map { Float($0) }
        return Loaded(frame: f, features: FeatureMatcher.features(in: grey, count: 500), depth: depth)
    }
    let t0 = Date()
    let la = a.compactMap(load), lb = b.compactMap(load)
    print(String(format: "described in %.1f s", Date().timeIntervalSince(t0)))

    func depth(_ l: Loaded, at p: SIMD2<Float>) -> Float? {
        let f = l.frame
        let dx = Int(p.x / Float(f.width) * Float(f.depthW)), dy = Int(p.y / Float(f.height) * Float(f.depthH))
        var s: [Float] = []
        for y in max(0, dy - 1)...min(f.depthH - 1, dy + 1) {
            for x in max(0, dx - 1)...min(f.depthW - 1, dx + 1) {
                let d = l.depth[y * f.depthW + x]
                if d > 0.1, d < 6 { s.append(d) }
            }
        }
        guard s.count >= 5 else { return nil }
        s.sort()
        // A pixel on a depth edge (spread over 5 cm) is not trusted.
        guard s.last! - s.first! < 0.05 else { return nil }
        return s[s.count / 2]
    }

    var rng = SystemRandomNumberGenerator()
    var fits: [(ia: Int, ib: Int, fit: Upright, inliers: Int, matches: Int, residual: Float)] = []
    for (ib, fb) in lb.enumerated() {
        for (ia, fa) in la.enumerated() {
            let pairs = FeatureMatcher.match(fa.features, fb.features)
            guard pairs.count >= minMatches else { continue }
            var pa: [SIMD3<Float>] = [], pb: [SIMD3<Float>] = []
            for (i, j) in pairs {
                let p = fa.features[i].point, q = fb.features[j].point
                guard let da = depth(fa, at: p), let db = depth(fb, at: q) else { continue }
                pa.append(fa.frame.world(p, depth: da))
                pb.append(fb.frame.world(q, depth: db))
            }
            guard pa.count >= 12 else { continue }
            // RANSAC on two pairs at a time: they fix the turn (their horizontal difference) and the shift.
            var best: [Int] = []
            for _ in 0..<400 {
                let i = Int.random(in: 0..<pa.count, using: &rng), j = Int.random(in: 0..<pa.count, using: &rng)
                guard i != j else { continue }
                let va = pa[j] - pa[i], vb = pb[j] - pb[i]
                let ha = simd_length(SIMD2(va.x, va.z)), hb = simd_length(SIMD2(vb.x, vb.z))
                guard ha > 0.05, abs(ha - hb) < 0.03, abs(va.y - vb.y) < 0.03 else { continue }
                let m = Upright.fit([pa[i], pa[j]], [pb[i], pb[j]])
                let inl = pa.indices.filter { simd_distance(m.apply(pa[$0]), pb[$0]) < 0.04 }
                if inl.count > best.count { best = inl }
            }
            guard best.count >= 10 else { continue }
            var m = Upright.fit(best.map { pa[$0] }, best.map { pb[$0] })
            var inl = pa.indices.filter { simd_distance(m.apply(pa[$0]), pb[$0]) < 0.03 }
            if inl.count >= 8 { m = Upright.fit(inl.map { pa[$0] }, inl.map { pb[$0] }) }
            inl = pa.indices.filter { simd_distance(m.apply(pa[$0]), pb[$0]) < 0.03 }
            let res = inl.map { simd_distance(m.apply(pa[$0]), pb[$0]) }.sorted()
            fits.append((ia, ib, m, inl.count, pairs.count, res.isEmpty ? 1 : res[res.count / 2]))
        }
    }
    print("pairs with a fit (≥ \(minMatches) matches, ≥ 10 agreeing in 3D): \(fits.count)")
    let strong = fits.filter { $0.inliers >= (ProcessInfo.processInfo.environment["PIP_MIN_AGREE"].flatMap { Int($0) } ?? 15) }.sorted { $0.inliers > $1.inliers }
    for f in strong.prefix(25) {
        print(String(format: "A%03d ↔ B%03d: %3d matches, %3d agree in 3D (median %.1f cm): %@", f.ia, f.ib, f.matches, f.inliers, f.residual * 100, f.fit.description))
    }
    // Do the strong fits agree with each other? Each one against the best.
    if let ref = strong.first {
        print("against the strongest fit:")
        for f in strong.prefix(25) {
            let dyaw = (f.fit.yaw - ref.fit.yaw) * 180 / .pi
            // How far a point 1 m from B's camera of the reference pair lands between the two fits.
            let probe = lb[ref.ib].frame.world(SIMD2(Float(lb[ref.ib].frame.width) / 2, Float(lb[ref.ib].frame.height) / 2), depth: 1)
            let inA = Upright(yaw: -ref.fit.yaw, t: .zero).apply(probe - ref.fit.t)
            let d = simd_distance(f.fit.apply(inA), ref.fit.apply(inA))
            print(String(format: "  A%03d ↔ B%03d: turn %+5.1f°, a point 1 m ahead %.1f cm apart", f.ia, f.ib, dyaw, d * 100))
        }
    }
}
