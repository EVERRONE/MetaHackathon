import Foundation
import Testing
import simd
@testable import PipCore

@Suite struct MapPieceTests {
    static func camera(at p: simd_float3, heading degrees: Float) -> simd_float4x4 {
        let a = degrees * .pi / 180
        var m = simd_float4x4(simd_quatf(angle: a, axis: simd_float3(0, 1, 0)))
        m.columns.3 = simd_float4(p, 1)
        return m
    }

    @Test func posesRoundTrip() throws {
        let pose = Self.camera(at: simd_float3(1, 1.4, -2), heading: 40)
        var piece = MapPiece()
        piece.keyframes = [MapKeyframe(pose: pose)]
        #expect(piece.keyframes[0].pose == pose)
        let back = try JSONDecoder().decode(MapPiece.self, from: JSONEncoder().encode(piece))
        #expect(back.keyframes[0].pose == pose)
        #expect(simd_distance(back.keyframes[0].position, simd_float3(1, 1.4, -2)) < 1e-6)
    }

    /// Pieces saved before 1 Nov carry surface points and image fingerprints: they still load.
    @Test func olderPiecesStillLoad() throws {
        let id = UUID()
        let json = """
        {"id": "\(id.uuidString)", "created": 800000000, "updated": 800000100,
         "points": [0, 1, 2], "normals": [0, 1, 0], "classes": [2],
         "keyframes": [{"poseValues": [1,0,0,0, 0,1,0,0, 0,0,1,0, 3,4,5,1], "printData": "AACAPw==", "time": 800000050}],
         "location": {"latitude": 50.8, "longitude": 4.4, "accuracy": 30}}
        """
        let piece = try JSONDecoder().decode(MapPiece.self, from: Data(json.utf8))
        #expect(piece.id == id)
        #expect(piece.keyframes.count == 1)
        #expect(piece.keyframes[0].position == simd_float3(3, 4, 5))
        #expect(piece.location?.accuracy == 30)
        #expect(piece.light == nil)
    }
}

/// The light a room was mapped in (see MapLight).
@Suite struct MapLightTests {
    @Test func piecesKeepTheirLightAndOldOnesStillLoad() throws {
        var piece = MapPiece()
        piece.light = MapLight(intensity: 980, temperature: 5600)
        let data = try JSONEncoder().encode(piece)
        #expect(try JSONDecoder().decode(MapPiece.self, from: data).light == piece.light)
        // A piece saved before lights were kept.
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["light"] = nil
        let old = try JSONDecoder().decode(MapPiece.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.light == nil)
    }
}
