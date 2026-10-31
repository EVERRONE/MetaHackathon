import Testing
import simd
@testable import PipCore

@Suite struct RayFusionTests {
    let target = simd_float3(0.2, -0.1, -0.6)

    func look(from origin: simd_float3, distanceError: Float = 0, sigma: Float = 0.015, lateral: Float = 0.002) -> RayFusion.Observation {
        let v = target - origin
        return .init(origin: origin, direction: v, distance: simd_length(v) + distanceError, distanceSigma: sigma, lateralSigma: lateral, time: 0)
    }

    @Test func oneLookIsItsLidarPoint() throws {
        let o = look(from: .zero)
        let x = try #require(RayFusion.fuse([o]))
        #expect(simd_distance(x, target) < 1e-4)
    }

    @Test func twoRaysCrossWithoutDepth() throws {
        var a = look(from: .zero), b = look(from: simd_float3(0.3, 0, 0))
        a.distance = nil
        b.distance = nil
        let x = try #require(RayFusion.fuse([a, b]))
        #expect(simd_distance(x, target) < 1e-3)
    }

    @Test func aSecondViewFixesABiasedDepth() throws {
        // LiDAR 5 cm too far in both looks (a glossy surface); the views are ~25° apart.
        let a = look(from: .zero, distanceError: 0.05, sigma: 0.03)
        let b = look(from: simd_float3(0.3, 0, -0.1), distanceError: 0.05, sigma: 0.03)
        let one = try #require(RayFusion.fuse([a]))
        let two = try #require(RayFusion.fuse([a, b]))
        #expect(simd_distance(one, target) > 0.04)
        #expect(simd_distance(two, target) < 0.01)
        #expect(RayFusion.angle(a, b) > 20)
    }

    @Test func parallelRaysWithoutDepthAreUndetermined() {
        var a = look(from: .zero), b = look(from: .zero)
        a.distance = nil
        b.distance = nil
        #expect(RayFusion.fuse([a, b]) == nil)
    }

    @Test func lateralErrorIsTheDistanceFromTheRay() {
        let o = RayFusion.Observation(origin: .zero, direction: simd_float3(0, 0, -1), distance: nil, distanceSigma: 0.1, lateralSigma: 0.01, time: 0)
        #expect(abs(RayFusion.lateralError(simd_float3(0.03, 0.04, -2), o) - 0.05) < 1e-5)
    }
}
