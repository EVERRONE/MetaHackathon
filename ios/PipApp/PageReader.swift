import ARKit
import CoreGraphics
import PipCore
import simd

/// Reading mode: the user leafs through paper instructions in front of the camera, and a page is
/// taken by itself once the phone is held still over a page Pip has not seen yet. No buttons.
@MainActor
final class PageReader {
    static let maxPages = 30
    /// The phone must be this still over this long: under 1 cm and 2 degrees in 0.45 s.
    static let steadyWindow: TimeInterval = 0.45
    static let maxMove: Float = 0.01
    static let maxTurn: Float = 2 * .pi / 180
    /// A page whose fingerprint differs from the last one by fewer bits is the same page.
    static let samePageBits = 10

    private(set) var pages: [Data] = []
    var onPage: ((Int) -> Void)?

    private var hashes: [UInt64] = []
    private var poses: [(time: TimeInterval, transform: simd_float4x4)] = []
    private var lastCapture: TimeInterval = 0
    private var lastCheck: TimeInterval = 0

    func feed(_ frame: ARFrame) {
        let t = frame.timestamp
        poses.append((t, frame.camera.transform))
        poses.removeAll { t - $0.time > Self.steadyWindow + 0.1 }
        guard pages.count < Self.maxPages, t - lastCapture > 1.2, t - lastCheck > 0.3,
              let first = poses.first, t - first.time >= Self.steadyWindow, isSteady(from: first.transform, to: frame.camera.transform) else { return }
        lastCheck = t
        // A tiny image is enough to tell pages apart; the full one is made only for a new page.
        guard let thumb = FrameSnapshot(frame: frame, maxSide: 64) else { return }
        let hash = Self.fingerprint(thumb.image)
        if let last = hashes.last, (hash ^ last).nonzeroBitCount < Self.samePageBits { return }
        guard let snapshot = FrameSnapshot(frame: frame), let jpeg = SetOfMarks.jpeg(snapshot.image, quality: 0.85) else { return }
        pages.append(jpeg)
        hashes.append(hash)
        lastCapture = t
        onPage?(pages.count)
    }

    private func isSteady(from a: simd_float4x4, to b: simd_float4x4) -> Bool {
        let move = simd_distance(simd_float3(a.columns.3.x, a.columns.3.y, a.columns.3.z), simd_float3(b.columns.3.x, b.columns.3.y, b.columns.3.z))
        let ra = simd_float3x3(simd_make_float3(a.columns.0), simd_make_float3(a.columns.1), simd_make_float3(a.columns.2))
        let rb = simd_float3x3(simd_make_float3(b.columns.0), simd_make_float3(b.columns.1), simd_make_float3(b.columns.2))
        let r = ra.transpose * rb
        let turn = acos(max(-1, min(1, (r[0][0] + r[1][1] + r[2][2] - 1) / 2)))
        return move < Self.maxMove && turn < Self.maxTurn
    }

    /// Difference hash: 9×8 grey pixels, one bit per neighbour comparison.
    static func fingerprint(_ image: CGImage) -> UInt64 {
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hash: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) where pixels[y * w + x] > pixels[y * w + x + 1] {
                hash |= 1 << UInt64(y * (w - 1) + x)
            }
        }
        return hash
    }
}
