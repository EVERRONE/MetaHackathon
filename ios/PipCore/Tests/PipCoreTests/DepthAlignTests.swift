import Foundation
import simd
import Testing
@testable import PipCore

/// Laying one view's LiDAR surface onto another's finds the turn and shift between two sessions'
/// rooms from a start a few degrees and centimetres off (DinoLink's start from what the views look
/// like), and refuses views that do not overlap.
@Suite struct DepthAlignTests {
    /// A room in session A's coordinates: a floor, three walls and a cupboard.
    static func hit(_ o: SIMD3<Float>, _ d: SIMD3<Float>, plain: Bool = false) -> Float? {
        var best: Float?
        func plane(_ n: SIMD3<Float>, _ c: Float, inside: (SIMD3<Float>) -> Bool) {
            let den = simd_dot(n, d)
            guard abs(den) > 1e-6 else { return }
            let t = (c - simd_dot(n, o)) / den
            guard t > 0.05, inside(o + d * t), best.map({ t < $0 }) ?? true else { return }
            best = t
        }
        plane(SIMD3(0, 1, 0), -1.2) { _ in true }   // floor
        plane(SIMD3(0, 0, 1), -3.5) { _ in true }   // back wall
        if plain { return best }
        plane(SIMD3(1, 0, 0), -2.0) { _ in true }   // left wall
        plane(SIMD3(1, 0, 0), 2.5) { _ in true }    // right wall
        // A cupboard against the back wall: its front and its left side.
        plane(SIMD3(0, 0, 1), -2.9) { p in p.x > 0.4 && p.x < 1.4 && p.y < 0.6 }
        plane(SIMD3(1, 0, 0), 0.4) { p in p.z < -2.9 && p.y < 0.6 }
        return best
    }

    /// A 96 × 128 upright depth view of that room from `pose` (in A's room), given in the room
    /// coordinates `toSession` maps A's to; about the iPhone's field of view (77° across).
    static func view(pose: simd_float4x4, toSession: UprightTransform, plain: Bool = false) -> DepthView {
        let w = 96, h = 128
        let k = simd_float3x3(columns: (SIMD3(60, 0, 0), SIMD3(0, 60, 0), SIMD3(64, 48, 1)))
        var depth = [Float](repeating: 0, count: w * h)
        let o = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        for y in 0..<h {
            for x in 0..<w {
                // Upright pixel → sensor pixel → camera ray (as DepthView maps them; sensor 128 × 96).
                let px = Float(x) + 0.5, py = Float(y) + 0.5
                let qx = py, qy = 96 - px
                let ray = SIMD3((qx - 64) / 60, -(qy - 48) / 60, -1)
                let world = pose * SIMD4(ray, 0)
                if let t = hit(o, SIMD3(world.x, world.y, world.z), plain: plain) { depth[y * w + x] = t }
            }
        }
        return DepthView(width: w, height: h, sensorWidth: 128, sensorHeight: 96, intrinsics: k, pose: toSession.matrix * pose,
                         depthW: w, depthH: h, depth: depth)
    }

    static func pose(yaw degrees: Float, at p: SIMD3<Float>) -> simd_float4x4 {
        var m = UprightTransform(yaw: degrees * .pi / 180, t: p).matrix
        m.columns.3 = SIMD4(p, 1)
        return m
    }

    @Test func aLinkAFewDegreesOffIsLaidOntoTheRoom() throws {
        let truth = UprightTransform(yaw: 8 * .pi / 180, t: SIMD3(0.3, -0.05, 0.2))
        let a = Self.view(pose: Self.pose(yaw: 0, at: .zero), toSession: .identity)
        let b = Self.view(pose: Self.pose(yaw: 12, at: SIMD3(0.25, 0.05, -0.2)), toSession: truth)
        // Started 4° and about 10 cm off, as DINOv2's fit can be.
        let start = UprightTransform(yaw: truth.yaw + 4 * .pi / 180, t: truth.t + SIMD3(0.08, 0.02, -0.06))
        let laid = try #require(DepthAlign.refine(a, onto: b, from: start))
        #expect(laid.transform.turn(to: truth) * 180 / .pi < 0.3, "\(laid.transform)")
        #expect(laid.transform.distance(to: truth, at: SIMD3(0.9, -0.3, -2.9)) < 0.01, "\(laid.transform)")
        #expect(laid.overlap > 0.5)
        #expect(laid.rms < 0.005)
        // Walls three ways, the floor and a cupboard pin it down.
        #expect(laid.shiftUncertainty < 0.005 && laid.turnUncertainty < 0.2 * .pi / 180, "\(laid.shiftUncertainty) m, \(laid.turnUncertainty) rad")
    }

    @Test func aWallAndTheFloorAloneLeaveTheShiftAlongTheWallFree() throws {
        // A room of nothing but a plain wall and the floor: the wall slides along itself.
        let truth = UprightTransform(yaw: 5 * .pi / 180, t: SIMD3(0.2, 0, 0.1))
        let a = Self.view(pose: Self.pose(yaw: 0, at: .zero), toSession: .identity, plain: true)
        let b = Self.view(pose: Self.pose(yaw: 3, at: SIMD3(0.05, 0, 0.1)), toSession: truth, plain: true)
        let laid = try #require(DepthAlign.refine(a, onto: b, from: truth))
        // It lies well on the surfaces (the overlap alone would take it), yet the shift is free.
        #expect(laid.overlap > 0.3)
        #expect(laid.shiftUncertainty > 0.1, "\(laid.shiftUncertainty) m")
    }

    @Test func viewsOfOtherPlacesDoNotOverlap() {
        let a = Self.view(pose: Self.pose(yaw: 0, at: .zero), toSession: .identity)
        // Session B looks the other way, at the wall behind A's camera: nothing of A's view is in it.
        let b = Self.view(pose: Self.pose(yaw: 180, at: SIMD3(0, 0, -1)), toSession: .identity)
        let laid = DepthAlign.refine(a, onto: b, from: .identity)
        #expect(laid == nil || laid!.overlap < 0.3)
    }
}
