import simd

/// Which way something is from the user, for spoken directions ("to your left, about 2 m").
public enum Wayfinding {
    /// The angle (degrees) from straight ahead to `target`, about the vertical: positive to the
    /// right, negative to the left. "Ahead" is where the camera looks, flattened onto the floor;
    /// "right" follows from that and gravity, so it holds however the phone is held. (The camera's
    /// own x axis is the sensor's long side: in a phone held upright it points up or down, not
    /// right.)
    public static func bearing(to target: simd_float3, camera: simd_float4x4) -> Float {
        let position = simd_float3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let look = -simd_float3(camera.columns.2.x, 0, camera.columns.2.z)
        guard simd_length(look) > 1e-4 else { return 0 }
        let forward = simd_normalize(look)
        let right = simd_cross(forward, simd_float3(0, 1, 0))
        let v = target - position
        return atan2(simd_dot(v, right), simd_dot(v, forward)) * 180 / .pi
    }
}
