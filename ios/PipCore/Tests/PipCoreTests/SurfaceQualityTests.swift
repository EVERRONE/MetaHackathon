import Foundation
import Testing
import simd
@testable import PipCore

@Suite struct SurfaceQualityTests {
    @Test func averagingRemovesNoise() {
        var rng = SystemRandomNumberGenerator()
        // Twenty noisy measurements of the same floor point in one cube.
        let pts = (0..<20).map { _ in simd_float3(0.012, 0.0125 + Float.random(in: -0.006...0.006, using: &rng), 0.012) }
        let r = VoxelIndex.average(pts, normals: Array(repeating: simd_float3(0, 1, 0), count: 20), classes: Array(repeating: SurfaceClass.floor, count: 20), size: 0.025)
        #expect(r.points.count == 1)
        #expect(abs(r.points[0].y - 0.0125) < 0.003)
        #expect(r.classes == [SurfaceClass.floor])
        #expect(simd_distance(r.normals[0], simd_float3(0, 1, 0)) < 1e-5)
    }

    @Test func aMovedChairDoesNotPullTheFit() throws {
        // A room (walls, floor) with a big armchair; in the live view the chair stands 4 cm further:
        // close enough to be matched, so unweighted it pulls the fit along.
        var structure: [simd_float3] = [], chair: [simd_float3] = []
        func grid(_ into: inout [simd_float3], _ a: ClosedRange<Float>, _ b: ClosedRange<Float>, _ f: (Float, Float) -> simd_float3) {
            var u = a.lowerBound; while u <= a.upperBound { var v = b.lowerBound; while v <= b.upperBound { into.append(f(u, v)); v += 0.04 }; u += 0.04 }
        }
        grid(&structure, 0...4, 0...4) { simd_float3($0, 0, $1) }
        grid(&structure, 0...4, 0...2.5) { simd_float3(0, $1, $0) }
        grid(&structure, 0...4, 0...2.5) { simd_float3($0, $1, 0) }
        func armchair(at x: Float) -> [simd_float3] {
            var c: [simd_float3] = []
            grid(&c, x...(x + 1.2), 0...0.9) { simd_float3($0, $1, 1.0) }
            grid(&c, x...(x + 1.2), 1.0...1.9) { simd_float3($0, 0.9, $1) }
            grid(&c, 1.0...1.9, 0...0.9) { simd_float3(x, $1, $0) }
            return c
        }
        chair = armchair(at: 1.5)
        let stored = structure + chair
        let classes = Array(repeating: SurfaceClass.wall, count: structure.count) + Array(repeating: SurfaceClass.seat, count: chair.count)
        let truth = PointRegistration.transform(yaw: 0.3, translation: simd_float3(0.5, 0, -0.4))
        let liveWorld = VoxelIndex.downsample(structure.filter { simd_distance($0, simd_float3(1.2, 0.6, 1.0)) < 2.0 } + armchair(at: 1.54), size: 0.05)
        let source = liveWorld.map { (truth.inverse * simd_float4($0, 1)).xyz }
        let weighted = RegistrationTarget(points: stored, weights: classes.map(SurfaceClass.weight))
        let plain = RegistrationTarget(points: stored)
        let rw = try #require(MapLinker.refine(source: source, target: weighted, initial: truth))
        let rp = try #require(MapLinker.refine(source: source, target: plain, initial: truth))
        let p = simd_float3(3, 1, 3)
        let ew = simd_distance((rw.transform * simd_float4(p, 1)).xyz, (truth * simd_float4(p, 1)).xyz)
        let ep = simd_distance((rp.transform * simd_float4(p, 1)).xyz, (truth * simd_float4(p, 1)).xyz)
        print(String(format: "moved chair: %.1f mm off with furniture weighted, %.1f mm without", ew * 1000, ep * 1000))
        #expect(ew < 0.01)
        #expect(ew < ep)
    }

    @Test func furnitureAloneNeverMakesAFitUnambiguous() throws {
        // The only thing pinning the sideways direction is a chair: not firm enough to link.
        var floor: [simd_float3] = [], chair: [simd_float3] = []
        func grid(_ into: inout [simd_float3], _ a: ClosedRange<Float>, _ b: ClosedRange<Float>, _ f: (Float, Float) -> simd_float3) {
            var u = a.lowerBound; while u <= a.upperBound { var v = b.lowerBound; while v <= b.upperBound { into.append(f(u, v)); v += 0.04 }; u += 0.04 }
        }
        grid(&floor, 0...4, 0...4) { simd_float3($0, 0, $1) }
        grid(&chair, 1.5...2.7, 0...0.9) { simd_float3($0, $1, 1.0) }
        grid(&chair, 1.0...1.9, 0...0.9) { simd_float3(1.5, $1, $0) }
        let weights = Array(repeating: Float(1), count: floor.count) + Array(repeating: SurfaceClass.weight(SurfaceClass.seat), count: chair.count)
        let target = RegistrationTarget(points: floor + chair, weights: weights)
        let source = VoxelIndex.downsample(floor.filter { simd_distance($0, simd_float3(2, 0, 1.2)) < 1.5 } + chair, size: 0.06)
        let r = try #require(PointRegistration.align(source: source, target: target, initial: matrix_identity_float4x4))
        #expect(!r.wellConstrained)
    }
}
