import ARKit
import CoreImage
import simd

/// A copy of the LiDAR depth map at capture time (256×192, metres, sensor orientation).
struct DepthCopy {
    let width: Int
    let height: Int
    let values: [Float32]
    let confidence: [UInt8]?

    init?(_ data: ARDepthData?) {
        guard let data else { return nil }
        let map = data.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        width = CVPixelBufferGetWidth(map)
        height = CVPixelBufferGetHeight(map)
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        var v = [Float32](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width { v[y * width + x] = row[x] }
        }
        values = v

        if let conf = data.confidenceMap {
            CVPixelBufferLockBaseAddress(conf, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(conf, .readOnly) }
            let cRow = CVPixelBufferGetBytesPerRow(conf)
            if let cBase = CVPixelBufferGetBaseAddress(conf) {
                var c = [UInt8](repeating: 0, count: width * height)
                for y in 0..<height {
                    let row = cBase.advanced(by: y * cRow).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width { c[y * width + x] = row[x] }
                }
                confidence = c
            } else {
                confidence = nil
            }
        } else {
            confidence = nil
        }
    }

    /// Depth at a normalised position (0…1 in sensor orientation), if confident enough.
    func value(u: CGFloat, v: CGFloat, minConfidence: UInt8) -> Float? {
        let x = Int(u * CGFloat(width))
        let y = Int(v * CGFloat(height))
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = y * width + x
        if let confidence, confidence[i] < minConfidence { return nil }
        let d = values[i]
        return d.isFinite && d > 0.05 ? d : nil
    }
}

/// Everything needed to turn a pixel in the photo sent to the models back into a 3D point.
struct FrameSnapshot {
    /// Upright portrait image, long side ≤ 1280, as sent to SAM and Spark.
    let image: CGImage
    /// `camera.imageResolution`: the captured image in sensor (landscape) orientation.
    let sensorSize: CGSize
    let intrinsics: simd_float3x3
    let cameraTransform: simd_float4x4
    let depth: DepthCopy?

    private static let context = CIContext(options: [.cacheIntermediates: false])

    init?(frame: ARFrame, maxSide: CGFloat = 1280) {
        let upright = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let scale = maxSide / max(upright.extent.width, upright.extent.height)
        let scaled = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = Self.context.createCGImage(scaled, from: scaled.extent.integral) else { return nil }
        image = cg
        sensorSize = frame.camera.imageResolution
        intrinsics = frame.camera.intrinsics
        cameraTransform = frame.camera.transform
        depth = DepthCopy(frame.sceneDepth ?? frame.smoothedSceneDepth)
    }

    /// Snapshot pixel (upright, scaled) → captured-image pixel. The upright image is the sensor
    /// image rotated 90° clockwise, so x_sensor = y_upright and y_sensor = H − x_upright.
    func sensorPoint(_ p: CGPoint) -> CGPoint {
        let s = sensorSize.width / CGFloat(image.height)
        return CGPoint(x: p.y * s, y: sensorSize.height - p.x * s)
    }

    func depth(atSensor q: CGPoint, minConfidence: UInt8 = 1) -> Float? {
        depth?.value(u: q.x / sensorSize.width, v: q.y / sensorSize.height, minConfidence: minConfidence)
    }

    /// Unprojects a captured-image pixel at camera-space depth `d` (metres) into world space.
    /// ARKit's camera looks down −Z with +Y up, while image rows grow downwards.
    func worldPoint(sensor q: CGPoint, depth d: Float) -> simd_float3 {
        let fx = intrinsics[0][0], fy = intrinsics[1][1]
        let cx = intrinsics[2][0], cy = intrinsics[2][1]
        let x = (Float(q.x) - cx) / fx * d
        let y = -(Float(q.y) - cy) / fy * d
        let p = cameraTransform * simd_float4(x, y, -d, 1)
        return simd_float3(p.x, p.y, p.z)
    }
}
