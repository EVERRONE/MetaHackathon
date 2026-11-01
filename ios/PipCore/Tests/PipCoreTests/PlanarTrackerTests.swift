import CoreGraphics
import Foundation
import Testing
import simd
@testable import PipCore

/// The planar tracker on synthetic sequences with a known truth: a keyboard-like face (a grid of
/// identical keys, each with its own mark: a repeating texture) moved, turned and tilted over a
/// background, with motion blur and noise. The error is where the tracker puts a key against
/// where it is, in pixels.
@Suite struct PlanarTrackerTests {
    static let size = (w: 640, h: 480)

    /// A keyboard face 360×160: 12×4 keys of 26×34 with a stroke pattern of their own (seeded).
    static func keyboard() -> GrayImage {
        let w = 360, h = 160
        var img = GrayImage(width: w, height: h, fill: 200)
        var rng = SplitMix64(seed: 7)
        for row in 0..<4 {
            for col in 0..<12 {
                let x0 = 6 + col * 29, y0 = 6 + row * 38
                for y in y0..<(y0 + 34) { for x in x0..<(x0 + 26) { img.pixels[y * w + x] = 40 } }
                // A glyph: three short bright strokes at places of their own.
                for _ in 0..<3 {
                    let gx = x0 + 5 + Int(rng.next() % 14), gy = y0 + 5 + Int(rng.next() % 22)
                    let horizontal = rng.next() % 2 == 0
                    for k in 0..<7 {
                        let x = horizontal ? gx + k : gx, y = horizontal ? gy : gy + k
                        if x < x0 + 26, y < y0 + 34 { img.pixels[y * w + x] = 230 }
                    }
                }
            }
        }
        return img
    }

    /// A background with texture of its own (it must not be followed).
    static func background(seed: UInt64) -> GrayImage {
        var img = GrayImage(width: size.w, height: size.h, fill: 120)
        var rng = SplitMix64(seed: seed)
        for _ in 0..<400 {
            let x = Int(rng.next() % UInt64(size.w - 8)), y = Int(rng.next() % UInt64(size.h - 8)), v = Float(rng.next() % 256)
            for dy in 0..<6 { for dx in 0..<6 { img.pixels[(y + dy) * size.w + x + dx] = v } }
        }
        return img
    }

    /// The face drawn into the frame with homography `h` (face → frame), plus noise; blurred, it is
    /// averaged over the motion around `h` (half the step from `blurFrom` before it, half the same
    /// step after: a camera exposes around the frame's own time).
    static func frame(_ face: GrayImage, _ h: simd_float3x3, blurFrom: simd_float3x3? = nil, background bg: GrayImage, noise: Float, seed: UInt64) -> GrayImage {
        var out = bg
        let steps = blurFrom == nil ? 1 : 5
        var acc = [Float](repeating: 0, count: out.pixels.count)
        var hits = [Float](repeating: 0, count: out.pixels.count)
        face.pixels.withUnsafeBufferPointer { fp in
            for s in 0..<steps {
                let t = steps == 1 ? 1 : 0.5 + Float(s) / Float(steps - 1)
                let hs = blurFrom.map { b in Self.mix(b, h, t) } ?? h
                let inv = hs.inverse
                for y in 0..<size.h {
                    for x in 0..<size.w {
                        let q = inv * simd_float3(Float(x), Float(y), 1)
                        let u = q.x / q.z, v = q.y / q.z
                        guard u >= 0, v >= 0, u < Float(face.width - 1), v < Float(face.height - 1) else { continue }
                        acc[y * size.w + x] += face.sample(u, v, fp)
                        hits[y * size.w + x] += 1
                    }
                }
            }
        }
        var rng = SplitMix64(seed: seed)
        for i in out.pixels.indices {
            let covered = hits[i] / Float(steps)
            if covered > 0 { out.pixels[i] = out.pixels[i] * (1 - covered) + (acc[i] / max(hits[i], 1)) * covered }
            out.pixels[i] += (Float(rng.next() % 1000) / 1000 - 0.5) * 2 * noise
        }
        return out
    }

    static func mix(_ a: simd_float3x3, _ b: simd_float3x3, _ t: Float) -> simd_float3x3 {
        simd_float3x3(columns: (a.columns.0 * (1 - t) + b.columns.0 * t, a.columns.1 * (1 - t) + b.columns.1 * t, a.columns.2 * (1 - t) + b.columns.2 * t))
    }

    /// Face → frame: placed at `at`, turned by `degrees`, tilted (a small perspective) by `tilt`.
    static func pose(at: SIMD2<Float>, degrees: Float, tilt: Float = 0, scale: Float = 1) -> simd_float3x3 {
        let a = degrees * .pi / 180
        let r = simd_float3x3(columns: (SIMD3(cos(a) * scale, sin(a) * scale, tilt), SIMD3(-sin(a) * scale, cos(a) * scale, 0), SIMD3(at.x, at.y, 1)))
        let centre = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(-180, -80, 1)))
        return r * centre
    }

    struct Run { var maxError: Float; var meanError: Float; var lostAt: Int?; var errors: [Float] }

    /// Follows the face through the poses; per frame the largest error at three keys (the ones a
    /// user is pointed at). `blur`: frames blurred along their motion.
    static func run(_ poses: [simd_float3x3], blur: [Bool], noise: Float, background: GrayImage) -> Run {
        let face = keyboard()
        let first = frame(face, poses[0], background: background, noise: noise, seed: 1)
        let outline = [CGPoint(x: 0, y: 0), CGPoint(x: 360, y: 0), CGPoint(x: 360, y: 160), CGPoint(x: 0, y: 160)].map { poses[0].apply($0) }
        var tracker = PlanarTracker()
        guard tracker.start(image: first, outline: outline) else { return Run(maxError: .infinity, meanError: .infinity, lostAt: 0, errors: []) }
        // Key centres on the face, and where they are on the first frame (the reference).
        let keys = [CGPoint(x: 19, y: 23), CGPoint(x: 193, y: 99), CGPoint(x: 338, y: 137)]
        let onFirst = keys.map { poses[0].apply($0) }
        var errors: [Float] = []
        for k in 1..<poses.count {
            let img = frame(face, poses[k], blurFrom: blur[k] ? poses[k - 1] : nil, background: background, noise: noise, seed: UInt64(k + 1))
            guard tracker.track(img) == .tracking else { return Run(maxError: errors.max() ?? 0, meanError: 0, lostAt: k, errors: errors) }
            errors.append(zip(keys, onFirst).map { key, ref -> Float in
                let truth = poses[k].apply(key), seen = tracker.map(ref)
                return Float(hypot(truth.x - seen.x, truth.y - seen.y))
            }.max() ?? 0)
        }
        return Run(maxError: errors.max() ?? 0, meanError: errors.reduce(0, +) / Float(max(errors.count, 1)), lostAt: nil, errors: errors)
    }

    @Test func aKeyboardSlidAndTurnedStaysOnItsKeys() {
        // 40 frames: 150 px across, turned 25°, a little perspective, 3.75 px and 0.6° a frame.
        let poses = (0..<40).map { k -> simd_float3x3 in
            let t = Float(k) / 39
            return Self.pose(at: SIMD2(240 + 150 * t, 240 - 30 * t), degrees: 25 * t, tilt: 0.0003 * t)
        }
        let r = Self.run(poses, blur: Array(repeating: false, count: poses.count), noise: 4, background: Self.background(seed: 3))
        #expect(r.lostAt == nil)
        #expect(r.meanError < 0.5, "mean \(r.meanError) px")
        #expect(r.maxError < 1.5, "max \(r.maxError) px")
    }

    @Test func aFastMoveWithMotionBlurIsFollowedAndSettles() {
        // Still for 3 frames, then 14 frames of 10 px and 2° each (blurred along the motion), then
        // still again for 8 frames: the error during the move, and once it lies still again.
        let move = (0..<15).map { k -> simd_float3x3 in
            let t = Float(k) / 14
            return Self.pose(at: SIMD2(230 + 150 * t, 250 - 40 * t), degrees: -30 * t, scale: 1 + 0.15 * t)
        }
        let poses = Array(repeating: move[0], count: 3) + move + Array(repeating: move[14], count: 8)
        let blur = (0..<poses.count).map { $0 >= 3 && $0 < 3 + 15 }
        let r = Self.run(poses, blur: blur, noise: 4, background: Self.background(seed: 5))
        #expect(r.lostAt == nil)
        let moving = r.errors[2..<16], still = r.errors.suffix(6)
        #expect((moving.max() ?? 99) < 4, "moving: \(moving.map { String(format: "%.2f", $0) })")
        #expect((still.max() ?? 99) < 0.7, "still again: \(still.map { String(format: "%.2f", $0) })")
    }

    @Test func homographyFromFourPointsIsExact() throws {
        let h = Self.pose(at: SIMD2(300, 200), degrees: 17, tilt: 0.0005, scale: 1.2)
        let a: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(300, 10), SIMD2(290, 150), SIMD2(5, 140), SIMD2(150, 70)]
        let b = a.map { p -> SIMD2<Float> in let q = h.apply(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))); return SIMD2(Float(q.x), Float(q.y)) }
        let fit = try #require(PlanarTracker.dlt(a, b))
        for p in a {
            let t = h.apply(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))), f = fit.apply(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            #expect(hypot(t.x - f.x, t.y - f.y) < 0.01)
        }
    }
}
