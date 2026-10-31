#if arch(arm64)
import CoreGraphics
import CoreML
import CoreVideo
import Testing
@testable import PipCore

/// The seed (from an upright snapshot) and the live frames (from the camera in sensor orientation)
/// must reach EdgeTAM the same way up, and the seed mask must lie on the object: these pin the
/// orientations down.
@Suite struct EdgeTAMTests {
    @Test func maskKeepsImageRowsTopDown() {
        // The top-left quarter of a 960×1280 snapshot.
        let ring = [CGPoint(x: 0, y: 0), CGPoint(x: 480, y: 0), CGPoint(x: 480, y: 640), CGPoint(x: 0, y: 640)]
        let m = EdgeTAM.Input.mask(polygons: [ring], in: CGSize(width: 960, height: 1280))
        #expect(m[10 * 1024 + 10] == 1)
        #expect(m[10 * 1024 + 600] == 0)
        #expect(m[600 * 1024 + 10] == 0)
        #expect(m[1000 * 1024 + 1000] == 0)
        let count = m.reduce(0) { $0 + Int($1) }
        #expect(abs(count - 512 * 512) < 2 * 1024)
    }

    @Test func copyFollowsStrides() throws {
        // 2 × 3 values stored with padded rows (a row stride of 4), as the Neural Engine can return them.
        let storage = UnsafeMutablePointer<Float16>.allocate(capacity: 8)
        for (i, v) in [1, 2, 3, -1, 4, 5, 6, -1].enumerated() { storage[i] = Float16(v) }
        let a = try MLMultiArray(dataPointer: storage, shape: [2, 3], dataType: .float16, strides: [4, 1]) { $0.deallocate() }
        #expect(EdgeTAM.copy(a) == [1, 2, 3, 4, 5, 6])
    }

    @Test func snapshotsArriveUpright() throws {
        // Red top-left quarter: it must stay top-left in the encoder's input.
        let image = try #require(Self.quarters(width: 96, height: 128))
        let input = EdgeTAM.Input()
        let pb = try #require(input.image(image))
        #expect(CVPixelBufferGetWidth(pb) == 1024 && CVPixelBufferGetHeight(pb) == 1024)
        #expect(Self.isRed(pb, x: 100, y: 100))
        #expect(!Self.isRed(pb, x: 900, y: 100))
        #expect(!Self.isRed(pb, x: 100, y: 900))
    }

    @Test func cameraFramesAreTurnedUpright() throws {
        // A sensor-orientation frame (landscape) with its top-left quarter red: turned `.right` as a
        // portrait iPhone shows it, that corner is the upright image's top-right, as FrameSnapshot's
        // sensorPoint has it (sensor x = upright y, sensor y = H − upright x).
        let sensor = try #require(Self.buffer(width: 192, height: 144, redQuarter: true))
        let input = EdgeTAM.Input()
        let pb = try #require(input.image(sensor, orientation: .right))
        #expect(Self.isRed(pb, x: 900, y: 100))
        #expect(!Self.isRed(pb, x: 100, y: 100))
        #expect(!Self.isRed(pb, x: 900, y: 900))
    }

    // MARK: Helpers

    static func quarters(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        // The context's y grows upwards: the top-left quarter.
        ctx.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
        return ctx.makeImage()
    }

    static func buffer(width: Int, height: Int, redQuarter: Bool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let row = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * row + x * 4
                let red = redQuarter && x < width / 2 && y < height / 2
                p[0] = red ? 0 : 255  // B
                p[1] = 0              // G
                p[2] = red ? 255 : 0  // R
                p[3] = 255
            }
        }
        return pb
    }

    static func isRed(_ pb: CVPixelBuffer, x: Int, y: Int) -> Bool {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(pb) + x * 4
        return p[2] > 180 && p[0] < 80
    }
}
#endif

#if arch(arm64)
/// The outline Pip draws from EdgeTAM's mask.
@Suite struct EdgeTAMOutlineTests {
    static func mask(_ w: Int, _ h: Int, _ inside: (Int, Int) -> Bool) -> [UInt8] {
        var m = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w where inside(x, y) { m[y * w + x] = 1 } }
        return m
    }

    @Test func aRectangleBecomesItsFourCorners() {
        let m = Self.mask(40, 30) { x, y in x >= 10 && x < 30 && y >= 5 && y < 25 }
        let ring = EdgeTAM.outline(m, width: 40, height: 30)
        #expect(ring.count == 4)
        let xs = ring.map(\.x), ys = ring.map(\.y)
        #expect(xs.min() == 10.5 && xs.max() == 29.5 && ys.min() == 5.5 && ys.max() == 24.5)
    }

    @Test func aDiscIsTracedAllRound() {
        let m = Self.mask(100, 100) { x, y in hypot(Double(x) - 50, Double(y) - 50) < 30 }
        let ring = EdgeTAM.outline(m, width: 100, height: 100)
        #expect(ring.count >= 12 && ring.count <= 80)
        // Every point lies on the circle, and the points go all the way round.
        for p in ring { #expect(abs(hypot(p.x - 50, p.y - 50) - 29.5) < 1.6) }
        let angles = Set(ring.map { Int((atan2($0.y - 50, $0.x - 50) + .pi) / (2 * .pi) * 8) % 8 })
        #expect(angles.count == 8)
    }

    @Test func onlyTheLargestRegionCounts() {
        let m = Self.mask(60, 40) { x, y in (x >= 2 && x < 6 && y >= 2 && y < 6) || (x >= 20 && x < 50 && y >= 10 && y < 30) }
        let ring = EdgeTAM.outline(m, width: 60, height: 40)
        #expect(ring.allSatisfy { $0.x > 19 })
    }

    @Test func aThinShapeDoesNotStopHalfway() {
        // An L: the trace passes its corner pixel twice.
        let m = Self.mask(30, 30) { x, y in (x >= 5 && x < 8 && y >= 5 && y < 25) || (x >= 5 && x < 25 && y >= 22 && y < 25) }
        let ring = EdgeTAM.outline(m, width: 30, height: 30)
        let xs = ring.map(\.x), ys = ring.map(\.y)
        #expect(xs.max()! > 24 && ys.max()! > 24 && ys.min()! < 6)
    }
}
#endif
