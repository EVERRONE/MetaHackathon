import Accelerate
import CoreGraphics
import simd

/// Finds an object again anywhere in a frame, turned or moved however far: corners with a
/// description of their surroundings (ORB's way: an orientation from the patch's intensity
/// centroid and 256 pairwise comparisons in a rotated pattern, on a smoothed image, at two
/// scales), matched by Hamming distance with a ratio test, and a homography that tens of matches
/// agree with (RANSAC). A key's look-alike on a keyboard matches a single descriptor at most; the
/// homography needs the whole face to agree, so the object is never found at a wrong place.
public struct FeatureMatcher: Sendable {
    public struct Feature: Sendable {
        /// Position in the image the features were found in (level 0 pixels).
        public var point: SIMD2<Float>
        /// 256 bits.
        public var bits: (UInt64, UInt64, UInt64, UInt64)
    }

    static let patchRadius = 15
    /// The sampling pattern: 256 pairs of offsets within the patch (fixed, so descriptors from
    /// different frames compare).
    static let pattern: [(SIMD2<Float>, SIMD2<Float>)] = {
        var rng = SplitMix64(seed: 0x5EED_0F_FACE)
        func offset() -> SIMD2<Float> {
            // Roughly Gaussian (sum of uniforms), σ ≈ radius / 2.5, clipped to the patch.
            func g() -> Float { (0..<4).map { _ in Float(rng.next() % 10_000) / 10_000 }.reduce(0, +) - 2 }
            let r = Float(patchRadius - 2)
            return SIMD2(max(-r, min(r, g() * r / 1.6)), max(-r, min(r, g() * r / 1.6)))
        }
        return (0..<256).map { _ in (offset(), offset()) }
    }()

    /// Features on `image`, inside `polygon` if given (image pixels), at most `count`, found at
    /// full size, 0.7× and half size (an object seen nearer or further: a description holds over
    /// about a fifth of a change in size).
    public static func features(in image: GrayImage, inside polygon: [SIMD2<Float>]? = nil, count: Int = 400) -> [Feature] {
        var out: [Feature] = []
        for (l, scale) in [Float(1), Float(2).squareRoot(), 2].enumerated() {
            let level = scale == 1 ? image : image.resized(width: Int(Float(image.width) / scale), height: Int(Float(image.height) / scale))
            let smooth = level.smoothed()
            let area: [SIMD2<Float>] = polygon.map { $0.map { $0 / scale } } ?? [SIMD2(0, 0), SIMD2(Float(level.width), 0), SIMD2(Float(level.width), Float(level.height)), SIMD2(0, Float(level.height))]
            let corners = PlanarTracker.corners(in: level, inside: area, count: l == 0 ? count : count * 2 / 3, spacing: 5, avoiding: [])
            smooth.pixels.withUnsafeBufferPointer { p in
                level.pixels.withUnsafeBufferPointer { raw in
                    for c in corners {
                        let r = Float(patchRadius + 2)
                        guard c.x >= r, c.y >= r, c.x < Float(level.width) - r, c.y < Float(level.height) - r else { continue }
                        let angle = Self.orientation(level, raw, at: c)
                        out.append(Feature(point: c * scale, bits: Self.describe(smooth, p, at: c, angle: angle)))
                    }
                }
            }
        }
        return out
    }

    /// The patch's orientation: the direction of its intensity centroid.
    static func orientation(_ img: GrayImage, _ p: UnsafeBufferPointer<Float>, at c: SIMD2<Float>) -> Float {
        var mx: Float = 0, my: Float = 0
        let r = patchRadius
        let cx = Int(c.x), cy = Int(c.y)
        for dy in -r...r {
            let span = Int(sqrt(Float(r * r - dy * dy)))
            for dx in -span...span {
                let v = p[(cy + dy) * img.width + cx + dx]
                mx += Float(dx) * v
                my += Float(dy) * v
            }
        }
        return atan2(my, mx)
    }

    static func describe(_ img: GrayImage, _ p: UnsafeBufferPointer<Float>, at c: SIMD2<Float>, angle: Float) -> (UInt64, UInt64, UInt64, UInt64) {
        let ca = cos(angle), sa = sin(angle)
        var words: [UInt64] = [0, 0, 0, 0]
        for (i, pair) in pattern.enumerated() {
            let a = SIMD2(ca * pair.0.x - sa * pair.0.y, sa * pair.0.x + ca * pair.0.y) + c
            let b = SIMD2(ca * pair.1.x - sa * pair.1.y, sa * pair.1.x + ca * pair.1.y) + c
            if img.sample(a.x, a.y, p) < img.sample(b.x, b.y, p) { words[i >> 6] |= 1 << UInt64(i & 63) }
        }
        return (words[0], words[1], words[2], words[3])
    }

    @inline(__always) static func distance(_ a: Feature, _ b: Feature) -> Int {
        (a.bits.0 ^ b.bits.0).nonzeroBitCount + (a.bits.1 ^ b.bits.1).nonzeroBitCount
            + (a.bits.2 ^ b.bits.2).nonzeroBitCount + (a.bits.3 ^ b.bits.3).nonzeroBitCount
    }

    /// Matches each reference feature to its nearest in `frame` when it is clearly nearer than the
    /// second nearest, and the two agree both ways.
    public static func match(_ reference: [Feature], _ frame: [Feature], maxDistance: Int = 70, ratio: Float = 0.8) -> [(Int, Int)] {
        guard !reference.isEmpty, !frame.isEmpty else { return [] }
        var nearestFrame = [Int](repeating: -1, count: frame.count), nearestFrameD = [Int](repeating: .max, count: frame.count)
        var pairs: [(Int, Int)] = []
        var best = [(Int, Int, Int)]()   // (reference, frame, distance)
        for (i, r) in reference.enumerated() {
            var d1 = Int.max, d2 = Int.max, j1 = -1
            for (j, f) in frame.enumerated() {
                let d = distance(r, f)
                if d < d1 { d2 = d1; d1 = d; j1 = j } else if d < d2 { d2 = d }
                if d < nearestFrameD[j] { nearestFrameD[j] = d; nearestFrame[j] = i }
            }
            guard j1 >= 0, d1 <= maxDistance, Float(d1) < ratio * Float(d2) else { continue }
            best.append((i, j1, d1))
        }
        for (i, j, _) in best where nearestFrame[j] == i { pairs.append((i, j)) }
        return pairs
    }

    /// The homography from the reference's features to `frame`'s, if enough matches agree.
    public static func homography(from reference: [Feature], to frame: [Feature], minInliers: Int = 15) -> (h: simd_float3x3, inliers: Int)? {
        let pairs = match(reference, frame)
        guard pairs.count >= minInliers else { return nil }
        guard let fit = PlanarTracker.ransacHomography(from: pairs.map { reference[$0.0].point }, to: pairs.map { frame[$0.1].point }, threshold: 3, iterations: 600),
              fit.inliers.count >= minInliers else { return nil }
        return (fit.h, fit.inliers.count)
    }
}

extension GrayImage {
    /// A 5×5 box blur: descriptors compare smoothed intensities (noise-robust).
    func smoothed() -> GrayImage {
        var src = pixels, out = [Float](repeating: 0, count: pixels.count)
        let k = [Float](repeating: 0.2, count: 5)
        src.withUnsafeMutableBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                var a = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var b = vImage_Buffer(data: o.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                vImageSepConvolve_PlanarF(&a, &b, nil, 0, 0, k, 5, k, 5, 0, Pixel_F(0), vImage_Flags(kvImageEdgeExtend))
            }
        }
        return GrayImage(width: width, height: height, pixels: out)
    }
}
