import Foundation
import Testing
import simd
@testable import PipCore

/// A house in true world coordinates: room A (x 0–4) and room B (x 4–8), z 0–4, with a doorway
/// between them and different furniture in each. Surfaces are sampled every 3 cm, like ARKit's mesh.
private func house(step: Float = 0.03, offset: Float = 0) -> [simd_float3] {
    var pts: [simd_float3] = []
    func grid(_ a: ClosedRange<Float>, _ b: ClosedRange<Float>, _ f: (Float, Float) -> simd_float3) {
        var u = a.lowerBound + offset
        while u <= a.upperBound {
            var v = b.lowerBound + offset
            while v <= b.upperBound { pts.append(f(u, v)); v += step }
            u += step
        }
    }
    grid(0...8, 0...4) { simd_float3($0, 0, $1) }                        // floor
    grid(0...4, 0...2.5) { simd_float3(0, $1, $0) }                      // west wall
    grid(0...8, 0...2.5) { simd_float3($0, $1, 0) }                      // south wall
    grid(0...8, 0...2.5) { simd_float3($0, $1, 4) }                      // north wall
    grid(0...4, 0...2.5) { simd_float3(8, $1, $0) }                      // east wall
    grid(0...1.5, 0...2.5) { simd_float3(4, $1, $0) }                    // middle wall, doorway z 1.5–2.5
    grid(2.5...4, 0...2.5) { simd_float3(4, $1, $0) }
    // Room A: a table, a cabinet, a radiator.
    grid(1.0...2.2, 2.2...3.0) { simd_float3($0, 0.75, $1) }
    grid(2.8...3.6, 0...1.4) { simd_float3($0, $1, 0.4) }
    grid(0.0...0.4, 2.8...3.6) { simd_float3(3.6, $1 * 2, $0) }          // cabinet side (x = 3.6)
    grid(0.3...0.9, 1.0...2.0) { simd_float3(0.1, $0, $1) }              // radiator on the west wall
    // Room B: a sofa and a shelf.
    grid(5.0...7.0, 3.0...3.8) { simd_float3($0, 0.45, $1) }
    grid(6.5...7.5, 0...1.8) { simd_float3($0, $1, 0.3) }
    return pts
}

private func camera(at p: simd_float3, heading h: Float) -> simd_float4x4 {
    // Upright camera looking along (sin h, 0, cos h): its −Z is forward.
    let back = simd_float3(-sin(h), 0, -cos(h)), up = simd_float3(0, 1, 0)
    let right = simd_cross(up, back)
    return simd_float4x4(columns: (simd_float4(right, 0), simd_float4(up, 0), simd_float4(back, 0), simd_float4(p, 1)))
}

private func apply(_ m: simd_float4x4, _ p: simd_float3) -> simd_float3 { (m * simd_float4(p, 1)).xyz }

private func noisy(_ pts: [simd_float3], _ sigma: Float) -> [simd_float3] {
    var rng = SystemRandomNumberGenerator()
    return pts.map { q in q + simd_float3(Float.random(in: -sigma...sigma, using: &rng), Float.random(in: -sigma...sigma, using: &rng), Float.random(in: -sigma...sigma, using: &rng)) }
}

/// What the live session's mesh holds around the user, in that session's frame: its own sampling
/// of the surfaces, LiDAR noise, and tracking drift (a 0.3 % scale error and 0.2° of turn).
private func liveMesh(_ world: [simd_float3], near p: simd_float3, radius: Float, frame: simd_float4x4) -> [simd_float3] {
    let drift = PointRegistration.transform(yaw: 0.2 * .pi / 180, translation: .zero)
    let near = world.filter { simd_distance($0, p) < radius && $0.x < 4.05 }
    return noisy(VoxelIndex.downsample(near, size: 0.04), 0.008).map { q in
        let start = simd_float3(6, 0, 2)                      // session B started in room B
        return apply(frame * drift, start + (q - start) * 1.003)
    }
}

@Suite struct MapLinkingSimulationTests {
    @Test func aPlaceFromAnEarlierSessionComesBackToTheCentimetre() throws {
        // The two sessions sample the same surfaces differently (as two meshes do).
        let world = house(step: 0.035, offset: 0.011)
        let storedWorld = noisy(house(step: 0.03, offset: 0), 0.008)
        // Session A mapped room A (and saw into the doorway); its frame is turned and shifted.
        let toA = PointRegistration.transform(yaw: 25 * .pi / 180, translation: simd_float3(1, 0, -2))
        let pieceA = storedWorld.filter { $0.x < 4.6 }.map { apply(toA, $0) }
        let target = RegistrationTarget(points: VoxelIndex.downsample(pieceA, size: 0.04))
        let tapWorld = simd_float3(0.1, 0.6, 1.5)                          // on the radiator
        let tapInA = apply(toA, tapWorld)
        let keyframeA = toA * camera(at: simd_float3(2.0, 1.4, 1.0), heading: 0.3)

        // Session B starts in room B in a completely different frame, then walks into room A.
        let toB = PointRegistration.transform(yaw: -70 * .pi / 180, translation: simd_float3(-3, 0, 5))
        var consensus = LinkConsensus()
        var link: simd_float4x4?
        var seen: [simd_float3] = []
        let walk: [(simd_float3, Float)] = [(simd_float3(2.4, 1.4, 1.3), 0.55), (simd_float3(1.8, 1.4, 1.6), 0.1)]
        for (i, (position, heading)) in walk.enumerated() {
            let liveCamera = toB * camera(at: position, heading: heading)
            let live = liveMesh(world, near: position, radius: 3.5, frame: toB)
            seen += live
            let seed = MapLinker.seed(live: liveCamera, stored: keyframeA)
            let fit = try #require(PointRegistration.align(source: VoxelIndex.downsample(live, size: 0.08), target: target, initial: seed))
            #expect(fit.isMatch, "fit \(i): rms \(fit.rms) inliers \(fit.inlierRatio) constraint \(fit.constraint)")
            link = consensus.add(piece: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, fit: fit, camera: liveCamera, time: Double(i) * 3) ?? link
        }
        let coarse = try #require(link)

        // The fine fit over everything session B has meshed of room A so far.
        let refined = try #require(MapLinker.refine(source: VoxelIndex.downsample(seen, size: 0.03), target: target, initial: coarse))
        let tapInB = apply(refined.transform.inverse, tapInA)
        // Where session B's (drifted) world puts the tap: what the user would see.
        let drift = PointRegistration.transform(yaw: 0.2 * .pi / 180, translation: .zero)
        let start = simd_float3(6, 0, 2)
        let truth = apply(toB * drift, start + (tapWorld - start) * 1.003)
        let error = simd_distance(tapInB, truth)
        let predicted = refined.uncertainty(at: tapInA)
        print(String(format: "link: tap off by %.1f mm (predicted ±%.1f mm), rms %.1f mm, %d matched; coarse link off by %.1f mm",
                     error * 1000, predicted * 1000, refined.rms * 1000, refined.matched, simd_distance(apply(coarse.inverse, tapInA), truth) * 1000))
        #expect(error < 0.01)
        #expect(predicted < MapLinker.showWithin)
        #expect(predicted >= error, "the predicted uncertainty must not be optimistic")
    }

    @Test func farFromTheOverlapTheUncertaintyGrows() throws {
        let r = MapLinker.Refined(transform: matrix_identity_float4x4, rms: 0.005, inlierRatio: 0.9,
                                  covariance: simd_double4x4(diagonal: simd_double4(pow(0.2 * .pi / 180, 2), 1e-6, 1e-6, 1e-6)),
                                  centre: .zero, matched: 1000)
        // At the overlap: the 5 mm floor and the fit. 6 m away: turn and drift dominate (~2.6 cm).
        #expect(abs(r.uncertainty(at: .zero) - 0.0053) < 0.001)
        #expect(r.uncertainty(at: simd_float3(6, 0, 0)) > 0.025)
    }

    @Test func seedAndHeadingAgreeWithTheTrueTransform() {
        let toA = PointRegistration.transform(yaw: 0.4, translation: simd_float3(1, 0, 2))
        let toB = PointRegistration.transform(yaw: -1.1, translation: simd_float3(-2, 0, 0.5))
        let cam = camera(at: simd_float3(1, 1.5, 1), heading: 0.7)
        // The same camera seen in both frames: the seed is exactly B → A.
        let seed = MapLinker.seed(live: toB * cam, stored: toA * cam)
        let truth = toA * toB.inverse
        let p = simd_float3(3, 1, -2)
        #expect(simd_distance(apply(seed, p), apply(truth, p)) < 1e-4)
    }
}
