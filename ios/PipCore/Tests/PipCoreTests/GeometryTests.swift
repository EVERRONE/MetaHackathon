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
