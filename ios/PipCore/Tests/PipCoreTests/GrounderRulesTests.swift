import CoreGraphics
import Testing
@testable import PipCore

/// The rules that let Pip point without a verifier's check (see Grounder.ground).
@Suite struct GrounderRulesTests {
    static func instance(box: [Int], area: Int, confidence: Double) -> SegmentInstance {
        SegmentInstance(id: 1, prompts: [], confidence: confidence, box: box, area: area, centroid: [(box[0] + box[2]) / 2, (box[1] + box[3]) / 2], polygons: [])
    }

    @Test func aPointDeepInsideAKeyNeedsNoCheck() {
        let key = CGRect(x: 100, y: 100, width: 80, height: 80)
        #expect(Grounder.deepInside(CGPoint(x: 140, y: 140), key))
        #expect(Grounder.deepInside(CGPoint(x: 121, y: 125), key))
        // Near an edge, or outside: the model may mean the neighbour.
        #expect(!Grounder.deepInside(CGPoint(x: 110, y: 140), key))
        #expect(!Grounder.deepInside(CGPoint(x: 140, y: 175), key))
        #expect(!Grounder.deepInside(CGPoint(x: 200, y: 140), key))
    }

    @Test func aSolidMaskIsAWholeObject() {
        // The left statue on 1 Nov: SAM sure, compact.
        #expect(Grounder.solid(Self.instance(box: [424, 656, 481, 727], area: 2900, confidence: 0.906)))
        // The sliver beside the right statue: unsure and flat.
        #expect(!Grounder.solid(Self.instance(box: [477, 665, 520, 683], area: 500, confidence: 0.559)))
        // Sure, but a thin line (a cable edge).
        #expect(!Grounder.solid(Self.instance(box: [0, 0, 200, 20], area: 3000, confidence: 0.95)))
        // Sure, but a ring with nothing inside its box (an outline of a frame).
        #expect(!Grounder.solid(Self.instance(box: [0, 0, 100, 100], area: 2000, confidence: 0.95)))
    }
}
