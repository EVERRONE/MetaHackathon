import Foundation
import Testing
import simd
@testable import PipCore

/// A synthetic room: floor, three walls, a table and a cabinet, every 5 cm.
private func room(walls: Bool = true, furniture: Bool = true) -> [simd_float3] {
    var pts: [simd_float3] = []
    let step: Float = 0.05
    func grid(_ a: ClosedRange<Float>, _ b: ClosedRange<Float>, _ f: (Float, Float) -> simd_float3) {
        var u = a.lowerBound
        while u <= a.upperBound {
            var v = b.lowerBound
            while v <= b.upperBound { pts.append(f(u, v)); v += step }
            u += step
        }
    }
    grid(0...4, 0...4) { simd_float3($0, 0, $1) }
    if walls {
        grid(0...4, 0...2.5) { simd_float3(0, $1, $0) }      // wall x = 0
        grid(0...4, 0...2.5) { simd_float3(4, $1, $0) }      // wall x = 4
        grid(0...4, 0...2.5) { simd_float3($0, $1, 0) }      // wall z = 0 (no wall at z = 4)
    } else {
        grid(0...4, 0...2.5) { simd_float3(0, $1, $0) }      // only one wall
    }
    if furniture {
        grid(1.5...2.5, 1...1.8) { simd_float3($0, 0.75, $1) }  // table top
        grid(3.2...3.8, 0...1.2) { simd_float3($0, $1, 0.2) }   // cabinet front
        grid(0.2...0.8, 0...1.2) { simd_float3(3.2, $1, $0) }   // cabinet side
        grid(3.2...3.8, 0.2...0.8) { simd_float3($0, 1.2, $1) } // cabinet top
    }
    return pts
}

private func apply(_ m: simd_float4x4, _ p: simd_float3) -> simd_float3 { (m * simd_float4(p, 1)).xyz }

/// What one live view sees, in its own session's frame: part of the room, with sensor noise.
private func liveView(of target: [simd_float3], truth: simd_float4x4, around centre: simd_float3, radius: Float) -> [simd_float3] {
    var rng = SystemRandomNumberGenerator()
    let inv = truth.inverse
    let seen = target.filter { simd_distance($0, centre) < radius }
    let sampled = VoxelIndex.downsample(seen, size: 0.08)
    return sampled.map { p in
        let noise = simd_float3(Float.random(in: -0.005...0.005, using: &rng), Float.random(in: -0.005...0.005, using: &rng), Float.random(in: -0.005...0.005, using: &rng))
        return apply(inv, p + noise)
    }
}

@Suite struct PointRegistrationTests {
    @Test func yawRoundTrips() {
        let m = PointRegistration.transform(yaw: 0.7, translation: simd_float3(1, 2, 3))
        #expect(abs(PointRegistration.yaw(of: m) - 0.7) < 1e-5)
    }

    @Test func exactPairsSolveInClosedForm() throws {
        let truth = PointRegistration.transform(yaw: 0.4, translation: simd_float3(0.5, 0, -1.2))
        let src: [simd_float3] = [simd_float3(0, 0, 0), simd_float3(1, 0, 0), simd_float3(0, 1, 2), simd_float3(-1, 0.5, 1)]
        let pairs = src.map { ($0, apply(truth, $0)) }
        let (yaw, t) = try #require(PointRegistration.solve(pairs))
        #expect(abs(yaw - 0.4) < 1e-4)
        #expect(simd_distance(t, simd_float3(0.5, 0, -1.2)) < 1e-4)
    }

    @Test func aLiveViewIsLaidOntoTheStoredRoom() throws {
        let target = room()
        let truth = PointRegistration.transform(yaw: 37 * .pi / 180, translation: simd_float3(1.3, 0, -0.8))
        let source = liveView(of: target, truth: truth, around: simd_float3(2.5, 0.8, 1), radius: 2.2)
        // The start is off by 12 degrees and 30 cm, as from a similar but not identical viewpoint.
        let start = PointRegistration.transform(yaw: 49 * .pi / 180, translation: simd_float3(1.55, 0, -1.0))
        let t0 = Date()
        let r = try #require(PointRegistration.align(source: source, target: RegistrationTarget(points: target), initial: start))
        let seconds = Date().timeIntervalSince(t0)
        #expect(abs(r.yawDegrees - 37) < 1)
        #expect(simd_distance(r.translation, simd_float3(1.3, 0, -0.8)) < 0.03)
        #expect(r.rms < 0.02)
        #expect(r.inlierRatio > 0.8)
        #expect(r.isMatch)
        print(String(format: "room fit: yaw %.2f°, t (%.3f, %.3f, %.3f), rms %.1f mm, inliers %.0f%%, constraint %.3f, %.2f s",
                     r.yawDegrees, r.translation.x, r.translation.y, r.translation.z, r.rms * 1000, r.inlierRatio * 100, r.constraint, seconds))
    }

    @Test func aBareWallIsNeverLinked() throws {
        // Floor and one wall: the view slides along the wall without fitting any worse.
        let target = room(walls: false, furniture: false)
        let truth = PointRegistration.transform(yaw: 0.3, translation: simd_float3(0.4, 0, 0.6))
        let source = liveView(of: target, truth: truth, around: simd_float3(0.5, 1, 2), radius: 1.5)
        let r = try #require(PointRegistration.align(source: source, target: RegistrationTarget(points: target), initial: truth))
        print(String(format: "bare wall: constraint %.3f, rms %.1f mm", r.constraint, r.rms * 1000))
        #expect(!r.wellConstrained)
        #expect(!r.isMatch)
    }

    @Test func aWrongRoomFitsBadly() throws {
        // The live view is of a different room (no cabinet, table elsewhere): few points match.
        let stored = room()
        var other = room(walls: true, furniture: false)
        var u: Float = 0.2
        while u <= 1.2 { var v: Float = 2.5; while v <= 3.5 { other.append(simd_float3(u, 0.45, v)); v += 0.05 }; u += 0.05 }
        let source = liveView(of: other, truth: matrix_identity_float4x4, around: simd_float3(0.8, 0.6, 3), radius: 1.6)
        let r = PointRegistration.align(source: source, target: RegistrationTarget(points: stored), initial: matrix_identity_float4x4)
        if let r { print(String(format: "wrong room: rms %.1f mm, inliers %.0f%%, constraint %.3f", r.rms * 1000, r.inlierRatio * 100, r.constraint)) }
        #expect(r == nil || !r!.isMatch)
    }
}
