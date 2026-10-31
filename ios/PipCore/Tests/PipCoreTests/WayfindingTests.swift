import Testing
import simd
@testable import PipCore

@Suite struct WayfindingTests {
    /// An iPhone held upright (portrait), looking along −z: ARKit's camera x axis (the sensor's long
    /// side) then points down, y points to the user's right, z back.
    func portrait(at p: simd_float3 = .zero) -> simd_float4x4 {
        simd_float4x4(columns: (simd_float4(0, -1, 0, 0), simd_float4(1, 0, 0, 0), simd_float4(0, 0, 1, 0), simd_float4(p, 1)))
    }

    @Test func leftIsLeftWhenThePhoneIsUpright() {
        let cam = portrait()
        #expect(Wayfinding.bearing(to: simd_float3(-1, 0, -1), camera: cam) < -30)   // ahead to the left
        #expect(Wayfinding.bearing(to: simd_float3(1, 0, -1), camera: cam) > 30)     // ahead to the right
        #expect(abs(Wayfinding.bearing(to: simd_float3(0, 0, -2), camera: cam)) < 1) // straight ahead
        #expect(abs(Wayfinding.bearing(to: simd_float3(0, 0, 2), camera: cam)) > 170) // behind
        // The old way (camera x as "right") is down in portrait: its flat part is zero.
        #expect(abs(simd_float2(cam.columns.0.x, cam.columns.0.z).x) < 1e-6)
    }

    @Test func landscapeGivesTheSameAnswer() {
        // The same view in landscape: x to the right, y up.
        let cam = simd_float4x4(columns: (simd_float4(1, 0, 0, 0), simd_float4(0, 1, 0, 0), simd_float4(0, 0, 1, 0), simd_float4(0, 0, 0, 1)))
        #expect(Wayfinding.bearing(to: simd_float3(-1, 0, -1), camera: cam) < -30)
    }
}
