import CoreGraphics
import Foundation
import Testing
@testable import PipCore

@Suite struct GeometryTests {
    let square = SegmentInstance(id: 3, prompts: ["key"], confidence: 0.9, box: [100, 200, 140, 240], area: 1600,
                                 centroid: [120, 220], polygons: [[100, 200, 140, 200, 140, 240, 100, 240]])

    @Test func mappingIntoACropAndBackIsLossless() {
        let crop = CGRect(x: 80, y: 180, width: 100, height: 100)
        let inCrop = square.mapped(into: crop, scale: 2.5)
        #expect(inCrop.box == [50, 50, 150, 150])
        #expect(inCrop.area == 10_000)
        let back = inCrop.unmapped(from: crop, scale: 2.5)
        #expect(back.box == square.box)
        #expect(back.polygons == square.polygons)
        #expect(back.area == square.area)
    }

    @Test func containsUsesTheOutlineNotJustTheBox() {
        let triangle = SegmentInstance(id: 1, prompts: [], confidence: 1, box: [0, 0, 100, 100], area: 5000,
                                       centroid: [33, 66], polygons: [[0, 0, 0, 100, 100, 100]])
        #expect(Grounding.contains(triangle, CGPoint(x: 10, y: 80)))
        #expect(!Grounding.contains(triangle, CGPoint(x: 80, y: 10)))
    }

    @Test func speechTimingFollowsUTF16Anchors() {
        let text = "Zet één knop"
        let audio = SpokenAudio(pcm: Data(), characters: text.map(String.init), starts: (0..<text.count).map { Double($0) / 10 })
        let anchor = (text as NSString).range(of: "knop").location
        #expect(audio.startTime(atUTF16: anchor, in: text) == 0.8)
    }
}

@Suite struct OutlineShapeTests {
    /// A rotated rectangle with jagged, pixel-stepped edges, like a SAM mask of a key.
    func jaggedRect(angle: CGFloat) -> [CGPoint] {
        var pts: [CGPoint] = []
        let w: CGFloat = 60, h: CGFloat = 40
        let edges: [(CGPoint, CGPoint)] = [(CGPoint(x: -w/2, y: -h/2), CGPoint(x: w/2, y: -h/2)), (CGPoint(x: w/2, y: -h/2), CGPoint(x: w/2, y: h/2)),
                                           (CGPoint(x: w/2, y: h/2), CGPoint(x: -w/2, y: h/2)), (CGPoint(x: -w/2, y: h/2), CGPoint(x: -w/2, y: -h/2))]
        for (a, b) in edges {
            for k in 0..<10 {
                let t = CGFloat(k) / 10
                let jitter: CGFloat = k % 2 == 0 ? 0.8 : -0.8
                let x = a.x + (b.x - a.x) * t + jitter, y = a.y + (b.y - a.y) * t - jitter
                pts.append(CGPoint(x: 200 + x * cos(angle) - y * sin(angle), y: 100 + x * sin(angle) + y * cos(angle)))
            }
        }
        return pts
    }

    @Test func nearRectanglesBecomeRotatedRoundedRectangles() {
        let angle: CGFloat = 0.3
        let hull = OutlineShape.convexHull(jaggedRect(angle: angle))
        let rect = OutlineShape.minAreaRect(hull)!
        #expect(abs(rect.center.x - 200) < 1.5 && abs(rect.center.y - 100) < 1.5)
        #expect(abs(max(rect.width, rect.height) - 60) < 3 && abs(min(rect.width, rect.height) - 40) < 3)
        let out = OutlineShape.regularize(jaggedRect(angle: angle))
        #expect(out.count == 24)
        let area = abs(OutlineShape.signedArea(out))
        #expect(area > 60 * 40 * 0.9 && area < 60 * 40 * 1.05)
    }

    @Test func concaveShapesAreOnlySmoothed() {
        // An L shape (like an Enter key) must not be squared off.
        let l: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 60, y: 100),
                            CGPoint(x: 60, y: 40), CGPoint(x: 0, y: 40)]
        let out = OutlineShape.regularize(l)
        #expect(out.count == l.count * 2)
        let area = abs(OutlineShape.signedArea(out))
        #expect(area < 100 * 100 * 0.8)
    }
}
