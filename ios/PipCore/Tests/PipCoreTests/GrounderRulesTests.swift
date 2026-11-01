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

    @Test func symbolKeysAreNotText() {
        #expect(Grounder.symbolOnly(["⏻"]))
        #expect(Grounder.symbolOnly(["⊞", "⌘"]))
        #expect(!Grounder.symbolOnly(["F1"]))
        #expect(!Grounder.symbolOnly(["delete"]))
        #expect(!Grounder.symbolOnly([]))
        #expect(Grounder.describeSymbol("⏻").contains("power"))
    }

    @Test func aPointPlainlyOnASymbolKeyNeedsNoCheck() {
        // 2 Nov: the model's point on the top edge of the power key, delete to its right.
        let power = CGRect(x: 440, y: 485, width: 46, height: 22), delete = CGRect(x: 499, y: 484, width: 46, height: 22)
        let prtScr = CGRect(x: 381, y: 485, width: 46, height: 22)
        #expect(Grounder.plainlyOn(CGPoint(x: 474, y: 481), power, others: [delete, prtScr]))
        // Between two keys: checked.
        #expect(!Grounder.plainlyOn(CGPoint(x: 492, y: 495), power, others: [delete, prtScr]))
        // Far above any key: checked.
        #expect(!Grounder.plainlyOn(CGPoint(x: 462, y: 440), power, others: [delete, prtScr]))
    }

    static func outlined(_ id: Int, _ box: [Int]) -> SegmentInstance {
        let (x0, y0, x1, y1) = (box[0], box[1], box[2], box[3])
        return SegmentInstance(id: id, prompts: [], confidence: 0.9, box: box, area: (x1 - x0) * (y1 - y0),
                               centroid: [(x0 + x1) / 2, (y0 + y1) / 2], polygons: [[x0, y0, x1, y0, x1, y1, x0, y1]])
    }

    @Test func twoPointingsAgreeOnAKeyAndTheSymbolOnIt() {
        // 1 Nov: the power key, the ⏻ printed on it, and delete beside it.
        let power = Self.outlined(1, [440, 485, 486, 507]), symbol = Self.outlined(2, [455, 490, 465, 500])
        let delete = Self.outlined(3, [499, 484, 545, 506])
        #expect(Grounder.agree(power, power))
        #expect(Grounder.agree(power, symbol))
        #expect(Grounder.agree(symbol, power))
        #expect(!Grounder.agree(power, delete))
        #expect(!Grounder.agree(symbol, delete))
    }

    @Test func aPrintedSymbolStandsForTheKeyItIsOn() {
        func found(_ id: Int, _ box: [Int], by prompt: String) -> SegmentInstance {
            var i = Self.outlined(id, box)
            i.prompts = [prompt]
            return i
        }
        // 1 Nov: the second point landed on the ⊞ printed on the Windows key.
        let logo = found(1, [314, 715, 333, 734], by: "icon"), key = found(2, [291, 691, 358, 761], by: "key")
        let alt = found(3, [370, 691, 437, 761], by: "key")
        // A twelfth of a 600 × 600 crop at most.
        let most = 0.08 * 600 * 600
        #expect(Grounder.holder(of: logo, among: [logo, key, alt], kind: "key", maxArea: most)?.id == 2)
        // A key is not lifted.
        #expect(Grounder.holder(of: key, among: [logo, key, alt], kind: "key", maxArea: most) == nil)
        // A shaver's power symbol on its whole panel (outsized): the symbol stays.
        let symbol = found(4, [455, 650, 483, 680], by: "icon"), panel = found(5, [429, 472, 575, 708], by: "button")
        #expect(Grounder.holder(of: symbol, among: [symbol, panel], kind: "button", maxArea: most) == nil)
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
