import CoreGraphics
import Foundation
import Testing
import simd
@testable import PipCore

/// Finding a face again anywhere, without a prediction: moved far, turned, scaled.
@Suite struct FeatureMatcherTests {
    static func found(then: simd_float3x3, now: simd_float3x3, face: GrayImage, size: CGSize, bg: GrayImage) -> Float? {
        let f0 = PlanarTrackerTests.frame(face, then, background: bg, noise: 3, seed: 1)
        let f1 = PlanarTrackerTests.frame(face, now, background: bg, noise: 3, seed: 2)
        let outline = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0), CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)].map { then.apply($0) }
        let ref = FeatureMatcher.features(in: f0, inside: outline.map { SIMD2(Float($0.x), Float($0.y)) })
        let cur = FeatureMatcher.features(in: f1)
        guard let fit = FeatureMatcher.homography(from: ref, to: cur) else { return nil }
        // Error at three keys: the found homography maps reference (first frame) points onto now.
        let keys = [CGPoint(x: 19, y: 23), CGPoint(x: size.width / 2, y: size.height / 2), CGPoint(x: size.width - 20, y: size.height - 20)]
        return keys.map { k -> Float in
            let truth = now.apply(k), seen = fit.h.apply(then.apply(k))
            return Float(hypot(truth.x - seen.x, truth.y - seen.y))
        }.max()
    }

    @Test func aFaceIsFoundAgainFarAwayAndTurned() throws {
        let face = PlanarTrackerTests.keyboard(), bg = PlanarTrackerTests.background(seed: 13)
        let size = CGSize(width: 360, height: 160)
        let then = PlanarTrackerTests.pose(at: SIMD2(230, 240), degrees: 0)
        // (On a grid of near-identical keys, a turn and a change of size together are beyond it: on a
        // real keyboard, with its printed letters, 30° and 1.2× together were found, 1.9 px off.)
        for (now, label) in [(PlanarTrackerTests.pose(at: SIMD2(360, 260), degrees: 45), "130 px, 45°"),
                             (PlanarTrackerTests.pose(at: SIMD2(330, 250), degrees: 90), "100 px, 90°"),
                             (PlanarTrackerTests.pose(at: SIMD2(360, 240), degrees: 0, scale: 1.2), "130 px, 1.2×")] {
            let error = try #require(Self.found(then: then, now: now, face: face, size: size, bg: bg), "\(label): not found")
            #expect(error < 3, "\(label): \(error) px")
        }
    }

    @Test func aFaceThatIsNotThereIsNotFound() {
        let face = PlanarTrackerTests.keyboard(), bg = PlanarTrackerTests.background(seed: 17)
        let then = PlanarTrackerTests.pose(at: SIMD2(230, 240), degrees: 0)
        let f0 = PlanarTrackerTests.frame(face, then, background: bg, noise: 3, seed: 1)
        let outline = [CGPoint(x: 0, y: 0), CGPoint(x: 360, y: 0), CGPoint(x: 360, y: 160), CGPoint(x: 0, y: 160)].map { then.apply($0) }
        let ref = FeatureMatcher.features(in: f0, inside: outline.map { SIMD2(Float($0.x), Float($0.y)) })
        let empty = PlanarTrackerTests.background(seed: 99)
        #expect(FeatureMatcher.homography(from: ref, to: FeatureMatcher.features(in: empty)) == nil)
    }
}
