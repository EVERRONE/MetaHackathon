import Foundation
import simd

/// A view with its LiDAR depth, in the room coordinates of the session that took it: an upright
/// image of `width` × `height` pixels, an upright depth grid over it, the camera's sensor geometry
/// (ARKit's intrinsics, in the sensor's landscape pixels) and its pose. The same mapping as the
/// app's FrameSnapshot and Keyframes.Frame: upright pixel → sensor pixel → camera space → room.
public struct DepthView: Sendable {
    public var width: Int
    public var height: Int
    public var sensorWidth: Float
    public var sensorHeight: Float
    /// Column-major, as ARKit's: [0][0] fx, [1][1] fy, [2][0] cx, [2][1] cy.
    public var intrinsics: simd_float3x3
    /// Camera → room.
    public var pose: simd_float4x4
    public var depthW: Int
    public var depthH: Int
    /// Metres, row after row from the top left; 0 where there is none.
    public var depth: [Float]
    let inverse: simd_float4x4

    public init(width: Int, height: Int, sensorWidth: Float, sensorHeight: Float, intrinsics: simd_float3x3, pose: simd_float4x4,
                depthW: Int, depthH: Int, depth: [Float]) {
        precondition(depth.count == depthW * depthH)
        self.width = width
        self.height = height
        self.sensorWidth = sensorWidth
        self.sensorHeight = sensorHeight
        self.intrinsics = intrinsics
        self.pose = pose
        self.depthW = depthW
        self.depthH = depthH
        self.depth = depth
        inverse = pose.inverse
    }

    public var camera: SIMD3<Float> { SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z) }

    /// An upright pixel at camera-space depth `d`, in the room.
    public func world(_ p: SIMD2<Float>, depth d: Float) -> SIMD3<Float> {
        let s = sensorWidth / Float(height)
        let qx = p.y * s, qy = sensorHeight - p.x * s
        let x = (qx - intrinsics[2][0]) / intrinsics[0][0] * d, y = -(qy - intrinsics[2][1]) / intrinsics[1][1] * d
        let w = pose * SIMD4(x, y, -d, 1)
        return SIMD3(w.x, w.y, w.z)
    }

    /// Where a room point is in the upright image, nil behind the camera.
    public func pixel(of w: SIMD3<Float>) -> SIMD2<Float>? {
        let c = inverse * SIMD4(w, 1)
        let d = -c.z
        guard d > 0.05 else { return nil }
        let qx = c.x / d * intrinsics[0][0] + intrinsics[2][0], qy = -c.y / d * intrinsics[1][1] + intrinsics[2][1]
        let s = sensorWidth / Float(height)
        return SIMD2((sensorHeight - qy) / s, qx / s)
    }

    /// The depth at an upright pixel when the samples round it agree (TrustedDepth: not on a
    /// depth edge), as the stored snapshots' points are lifted.
    public func trustedDepth(at p: SIMD2<Float>) -> Float? {
        let dx = Int(p.x / Float(width) * Float(depthW)), dy = Int(p.y / Float(height) * Float(depthH))
        guard dx >= 0, dy >= 0, dx < depthW, dy < depthH else { return nil }
        var samples: [Float] = []
        for y in max(0, dy - 1)...min(depthH - 1, dy + 1) {
            for x in max(0, dx - 1)...min(depthW - 1, dx + 1) { samples.append(depth[y * depthW + x]) }
        }
        return TrustedDepth.of(samples)
    }

    /// Every depth cell's room point and surface normal, nil off the surface: no depth, a depth
    /// edge, or nearer to the camera than `minDepth` (what is held close, a laptop being used: it may
    /// have been moved since, it says nothing about the room).
    public func surface(minDepth: Float) -> (points: [SIMD3<Float>?], normals: [SIMD3<Float>]) {
        let n = depthW * depthH
        var points = [SIMD3<Float>?](repeating: nil, count: n)
        for y in 0..<depthH {
            for x in 0..<depthW {
                let d = depth[y * depthW + x]
                guard d >= max(minDepth, TrustedDepth.range.lowerBound), d <= TrustedDepth.range.upperBound else { continue }
                let p = SIMD2((Float(x) + 0.5) / Float(depthW) * Float(width), (Float(y) + 0.5) / Float(depthH) * Float(height))
                points[y * depthW + x] = world(p, depth: d)
            }
        }
        var normals = [SIMD3<Float>](repeating: .zero, count: n)
        var out = [SIMD3<Float>?](repeating: nil, count: n)
        for y in 1..<(depthH - 1) {
            for x in 1..<(depthW - 1) {
                let i = y * depthW + x
                guard let c = points[i], let l = points[i - 1], let r = points[i + 1], let u = points[i - depthW], let b = points[i + depthW] else { continue }
                // Not across a depth edge: the neighbours lie within 5 cm of the cell (a step of the
                // grid at 3 m is about 4 cm).
                let d = depth[i]
                guard abs(depth[i - 1] - d) < 0.05, abs(depth[i + 1] - d) < 0.05, abs(depth[i - depthW] - d) < 0.05, abs(depth[i + depthW] - d) < 0.05 else { continue }
                let nrm = simd_cross(r - l, b - u)
                let len = simd_length(nrm)
                guard len > 1e-9 else { continue }
                normals[i] = nrm / len
                out[i] = c
            }
        }
        return (out, normals)
    }
}

/// Lays one view's surface onto another's (ICP, point to plane), for the turn about the vertical
/// and the shift between their sessions' rooms. The surfaces are the LiDAR's: a change of light
/// does not move them. It refines a link found by what the views look like (DinoLink), which
/// alone is a few degrees off (1 Nov: -12° to -25° for one link); from such a start it settles on
/// the walls and furniture to about a centimetre.
public enum DepthAlign {
    public struct Result: Sendable {
        public var transform: UprightTransform
        /// The share of the first view's surface points that lie within 1.5 cm of the second's surface.
        public var overlap: Float
        /// Their root mean square distance from it, across it (metres).
        public var rms: Float
        /// Those points, in the first session's room: where the evidence is.
        public var agreeing: [SIMD3<Float>]
        /// How sure the surfaces make the turn (radians) and the shift at the evidence (metres).
        public var turnUncertainty: Float = 0
        public var shiftUncertainty: Float = 0
    }

    /// `start`: from `a`'s room to `b`'s. Points nearer than `minDepth` to either camera are left out.
    public static func refine(_ a: DepthView, onto b: DepthView, from start: UprightTransform, minDepth: Float = 0.8,
                              iterations: Int = 30, step: Int = 2) -> Result? {
        let (aPoints, _) = a.surface(minDepth: minDepth)
        var source: [SIMD3<Float>] = []
        for y in stride(from: 0, to: a.depthH, by: step) {
            for x in stride(from: 0, to: a.depthW, by: step) {
                if let p = aPoints[y * a.depthW + x] { source.append(p) }
            }
        }
        guard source.count >= 200 else { return nil }
        let (bPoints, bNormals) = b.surface(minDepth: minDepth)
        var yaw = Double(start.yaw)
        var t = SIMD3<Double>(Double(start.t.x), Double(start.t.y), Double(start.t.z))
        var maxDistance: Float = 0.3

        func associate(_ p: SIMD3<Float>, _ m: UprightTransform) -> (q: SIMD3<Float>, target: SIMD3<Float>, normal: SIMD3<Float>)? {
            let q = m.apply(p)
            guard let px = b.pixel(of: q) else { return nil }
            let cx = Int(px.x / Float(b.width) * Float(b.depthW)), cy = Int(px.y / Float(b.height) * Float(b.depthH))
            guard cx >= 0, cy >= 0, cx < b.depthW, cy < b.depthH else { return nil }
            let i = cy * b.depthW + cx
            guard let target = bPoints[i] else { return nil }
            return (q, target, bNormals[i])
        }

        for _ in 0..<iterations {
            let m = UprightTransform(yaw: Float(yaw), t: SIMD3(Float(t.x), Float(t.y), Float(t.z)))
            var h = simd_double4x4(0)
            var g = SIMD4<Double>(repeating: 0)
            var used = 0
            for p in source {
                guard let (q, target, n) = associate(p, m), simd_distance(q, target) < maxDistance else { continue }
                let r = Double(simd_dot(n, q - target))
                // The point turned (without the shift): its derivative along the turn.
                let turned = q - m.t
                let j = SIMD4<Double>(Double(n.x * turned.z - n.z * turned.x), Double(n.x), Double(n.y), Double(n.z))
                let w = 1 / max(1, abs(r) / 0.01)
                h += simd_double4x4(columns: (j * (w * j.x), j * (w * j.y), j * (w * j.z), j * (w * j.w)))
                g += j * (w * r)
                used += 1
            }
            guard used >= 200 else { return nil }
            h += simd_double4x4(diagonal: SIMD4(repeating: 1e-6))
            let delta = -(h.inverse * g)
            guard delta.x.isFinite else { return nil }
            yaw += delta.x
            t += SIMD3(delta.y, delta.z, delta.w)
            maxDistance = max(0.03, maxDistance * 0.8)
        }
        let m = UprightTransform(yaw: Float(UprightTransform.wrapped(yaw)), t: SIMD3(Float(t.x), Float(t.y), Float(t.z)))
        // On the surface: within 1.5 cm of it (across it: along it a point lies between the depth
        // grid's cells, 3 to 6 cm apart at a few metres), and by its cell.
        var agreeing: [SIMD3<Float>] = []
        var sumSquares: Float = 0
        // What the agreeing surface pins down: its information on the turn and the shift.
        var info = simd_double4x4(0)
        for p in source {
            guard let (q, target, n) = associate(p, m), simd_distance(q, target) < 0.08 else { continue }
            let across = abs(simd_dot(n, q - target))
            if across < 0.015 {
                agreeing.append(p)
                sumSquares += across * across
                let turned = q - m.t
                let j = SIMD4<Double>(Double(n.x * turned.z - n.z * turned.x), Double(n.x), Double(n.y), Double(n.z))
                info += simd_double4x4(columns: (j * j.x, j * j.y, j * j.z, j * j.w))
            }
        }
        guard !agreeing.isEmpty else { return nil }
        let rms = sqrt(sumSquares / Float(agreeing.count))
        let centre = agreeing.reduce(.zero, +) / Float(agreeing.count)
        let (turnStd, shiftStd) = Self.uncertainty(info, at: m.apply(centre) - m.t, sigma: Double(max(rms, 0.005)))
        return Result(transform: m, overlap: Float(agreeing.count) / Float(source.count), rms: rms, agreeing: agreeing,
                      turnUncertainty: turnStd, shiftUncertainty: shiftStd)
    }

    /// How sure the surfaces make the fit: the turn's standard deviation (radians) and the shift's at
    /// the evidence (metres, the root of the summed variances along x, y and z), for surfaces
    /// measured to `sigma`. A wall and the floor alone leave the shift along the wall free (a wall
    /// slides along itself, 31 Oct): there it is metres, and the link is the appearance's alone.
    static func uncertainty(_ info: simd_double4x4, at turned: SIMD3<Float>, sigma: Double) -> (Float, Float) {
        let cov = (info + simd_double4x4(diagonal: SIMD4(repeating: 1e-9))).inverse
        // The evidence moves with the turn about the vertical (its arm from the axis) and the shift.
        let arm = SIMD3<Double>(Double(turned.z), 0, -Double(turned.x))
        var shiftVariance = 0.0
        for k in 0..<3 {
            // Row k of A = [arm | I]: d(position_k) = arm_k dθ + dt_k.
            let a = SIMD4<Double>(arm[k], k == 0 ? 1 : 0, k == 1 ? 1 : 0, k == 2 ? 1 : 0)
            shiftVariance += simd_dot(a, cov * a)
        }
        let turn = sqrt(max(cov[0][0], 0)) * sigma, shift = sqrt(max(shiftVariance, 0)) * sigma
        return (turn.isFinite ? Float(turn) : .infinity, shift.isFinite ? Float(shift) : .infinity)
    }
}

extension UprightTransform {
    static func wrapped(_ a: Double) -> Double {
        var a = a
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }
}
