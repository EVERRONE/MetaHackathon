import Foundation
import Testing
import simd
@testable import PipCore

private func fit(yaw: Float, t: simd_float3, good: Bool = true) -> PointRegistration.Result {
    PointRegistration.Result(transform: PointRegistration.transform(yaw: yaw * .pi / 180, translation: t), yawDegrees: yaw, translation: t,
                             rms: good ? 0.008 : 0.008, inlierRatio: 0.9, constraint: good ? 0.2 : 0.0)
}

private func camera(at p: simd_float3, heading: Float = 0) -> simd_float4x4 {
    var m = PointRegistration.transform(yaw: heading * .pi / 180, translation: .zero)
    m.columns.3 = simd_float4(p, 1)
    return m
}

@Suite struct LinkConsensusTests {
    let piece = UUID()

    @Test func twoAgreeingFitsFromDifferentPlacesLink() throws {
        var c = LinkConsensus()
        #expect(c.add(piece: piece, fit: fit(yaw: 30, t: simd_float3(1, 0, 2)), camera: camera(at: .zero), time: 0) == nil)
        let second = c.add(piece: piece, fit: fit(yaw: 30.8, t: simd_float3(1.01, 0, 2.02)), camera: camera(at: simd_float3(0.7, 0, 0)), time: 5)
        let link = try #require(second)
        #expect(abs(PointRegistration.yaw(of: link) * 180 / .pi - 30.4) < 0.01)
    }

    @Test func theSameSpotTwiceIsNotEnough() {
        var c = LinkConsensus()
        _ = c.add(piece: piece, fit: fit(yaw: 30, t: simd_float3(1, 0, 2)), camera: camera(at: .zero), time: 0)
        #expect(c.add(piece: piece, fit: fit(yaw: 30, t: simd_float3(1, 0, 2)), camera: camera(at: simd_float3(0.1, 0, 0)), time: 3) == nil)
    }

    @Test func disagreeingOrAmbiguousFitsNeverLink() {
        var c = LinkConsensus()
        _ = c.add(piece: piece, fit: fit(yaw: 30, t: simd_float3(1, 0, 2)), camera: camera(at: .zero), time: 0)
        // 12 cm apart: two different answers.
        #expect(c.add(piece: piece, fit: fit(yaw: 30, t: simd_float3(1.12, 0, 2)), camera: camera(at: simd_float3(0.8, 0, 0)), time: 4) == nil)
        // A bare wall: never counts.
        var d = LinkConsensus()
        _ = d.add(piece: piece, fit: fit(yaw: 30, t: simd_float3(1, 0, 2), good: false), camera: camera(at: .zero), time: 0)
        #expect(d.add(piece: piece, fit: fit(yaw: 30, t: simd_float3(1, 0, 2), good: false), camera: camera(at: simd_float3(1, 0, 0)), time: 4) == nil)
    }

    @Test func turningRoundCountsAsADifferentView() {
        var c = LinkConsensus()
        _ = c.add(piece: piece, fit: fit(yaw: 10, t: simd_float3(0.5, 0, 0.5)), camera: camera(at: .zero, heading: 0), time: 0)
        #expect(c.add(piece: piece, fit: fit(yaw: 10.5, t: simd_float3(0.51, 0, 0.5)), camera: camera(at: .zero, heading: 35), time: 2) != nil)
    }

    @Test func oldFitsExpire() {
        var c = LinkConsensus()
        _ = c.add(piece: piece, fit: fit(yaw: 30, t: simd_float3(1, 0, 2)), camera: camera(at: .zero), time: 0)
        #expect(c.add(piece: piece, fit: fit(yaw: 30, t: simd_float3(1, 0, 2)), camera: camera(at: simd_float3(1, 0, 0)), time: 500) == nil)
    }
}

@Suite struct MapPieceTests {
    @Test func posesRoundTripAndMoveWithThePiece() throws {
        let pose = camera(at: simd_float3(1, 1.4, -2), heading: 40)
        var piece = MapPiece()
        piece.keyframes = [MapKeyframe(pose: pose, print: [0.1, 0.2])]
        piece.setSurface([simd_float3(0, 0, 0), simd_float3(1, 0, 0)])
        #expect(piece.keyframes[0].pose == pose)
        let data = try JSONEncoder().encode(piece)
        var back = try JSONDecoder().decode(MapPiece.self, from: data)
        back.loadSurface(piece.surfaceData())
        #expect(back.keyframes[0].pose == pose)
        let t = PointRegistration.transform(yaw: .pi / 2, translation: simd_float3(5, 0, 0))
        let moved = back.transformed(by: t)
        #expect(simd_distance(moved.surface[1], simd_float3(5, 0, -1)) < 1e-5)
        #expect(simd_distance(moved.keyframes[0].position, (t * simd_float4(1, 1.4, -2, 1)).xyz) < 1e-5)
    }

    @Test func surfacesRoundTripThroughTheBinaryFile() throws {
        var piece = MapPiece()
        piece.setSurface([simd_float3(1, 2, 3), simd_float3(-0.5, 0.25, 4)], normals: [simd_float3(0, 1, 0), simd_float3(0.6, 0, 0.8)],
                         classes: [SurfaceClass.floor, SurfaceClass.seat])
        piece.keyframes = [MapKeyframe(pose: matrix_identity_float4x4, print: [0.25, -1, 3])]
        var back = try JSONDecoder().decode(MapPiece.self, from: JSONEncoder().encode(piece))
        #expect(back.points.isEmpty)
        #expect(back.keyframes[0].print == [0.25, -1, 3])
        let blob = piece.surfaceData()
        #expect(blob.count == 8 + 2 * 16)
        back.loadSurface(blob)
        #expect(back.surface == piece.surface)
        #expect(back.classes == [SurfaceClass.floor, SurfaceClass.seat])
        #expect(simd_distance(back.surfaceNormals![1], simd_float3(0.6, 0, 0.8)) < 0.01)
    }

    @Test func fingerprintsFindTheMostAlikeViewsFirst() {
        var a = MapPiece(), b = MapPiece()
        a.keyframes = [MapKeyframe(pose: matrix_identity_float4x4, print: [1, 0, 0]), MapKeyframe(pose: matrix_identity_float4x4, print: [0, 1, 0])]
        b.keyframes = [MapKeyframe(pose: matrix_identity_float4x4, print: [0.9, 0.1, 0])]
        let found = FeaturePrint.candidates(for: [1, 0, 0], in: [a, b], maxDistance: 0.5)
        #expect(found.map(\.piece) == [a.id, b.id])
        #expect(found.first?.keyframe == 0)
    }
}
