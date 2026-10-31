import Foundation
import Testing
@testable import PipCore

private func sentences(_ events: [CueStreamEvent]) -> [SpokenSentence] {
    events.compactMap { if case .sentence(let s) = $0 { return s } else { return nil } }
}

private func run(_ chunks: [String]) -> [CueStreamEvent] {
    var parser = CueStreamParser()
    var events: [CueStreamEvent] = []
    for c in chunks { events += parser.feed(c) }
    events += parser.finish()
    return events
}

/// The word in `text` that a cue is bound to.
private func word(at anchor: Int, in text: String) -> String {
    let units = Array(text.utf16)
    var end = anchor
    while end < units.count, let s = Unicode.Scalar(units[end]), CharacterSet.alphanumerics.contains(s) { end += 1 }
    return String(decoding: units[anchor..<end], as: UTF16.self)
}

@Suite struct CueStreamParserTests {
    @Test func stripsTagsAndBindsToTheNextWord() {
        let s = sentences(run(["Found it. This is [[outline m=13]] the 10F breaker."]))
        #expect(s.map(\.text) == ["Found it.", "This is the 10F breaker."])
        #expect(s[0].cues.isEmpty)
        #expect(s[1].cues.count == 1)
        #expect(s[1].cues[0].cue == .outline(mark: 13))
        #expect(word(at: s[1].cues[0].anchor, in: s[1].text) == "the")
    }

    @Test func survivesTagsSplitAcrossChunks() {
        let chunks = ["Flip ", "[", "[mo", "ve m=13 dir", "=up]] it up", "ward. Then", " stop."]
        let s = sentences(run(chunks))
        #expect(s.map(\.text) == ["Flip it upward.", "Then stop."])
        #expect(s[0].cues.first?.cue == .move(mark: 13, direction: .up))
        #expect(word(at: s[0].cues[0].anchor, in: s[0].text) == "it")
    }

    @Test func tagAtSentenceEndBindsToLastWord() {
        let s = sentences(run(["That is the main switch [[outline m=2]]. Next one."]))
        #expect(s[0].text == "That is the main switch.")
        #expect(word(at: s[0].cues[0].anchor, in: s[0].text) == "switch")
        #expect(s[1].cues.isEmpty)
    }

    @Test func tagBeforeAnyTextBindsToFirstWord() {
        let s = sentences(run(["[[ring m=4 label=\"T2\"]] This screw."]))
        #expect(s[0].text == "This screw.")
        #expect(s[0].cues[0].cue == .ring(mark: 4, label: "T2"))
        #expect(s[0].cues[0].anchor == 0)
    }

    @Test func sideChannelIsNotSpoken() {
        let events = run(["It is off. [[state target=13 seen=off conf=0.9]]"])
        #expect(sentences(events).map(\.text) == ["It is off."])
        #expect(events.contains(.sideChannel(.state(["target": "13", "seen": "off", "conf": "0.9"]), raw: "[[state target=13 seen=off conf=0.9]]")))
    }

    @Test func invalidTagsAreReportedAndDropped() {
        let events = run(["Look [[sparkle m=3]] here. And [[outline]] there."])
        #expect(sentences(events).map(\.text) == ["Look here.", "And there."])
        #expect(events.filter { if case .invalidTag = $0 { return true } else { return false } }.count == 2)
    }

    @Test func decimalsAndNewlines() {
        let s = sentences(run(["Set it to 2.5 bar\nThen wait."]))
        #expect(s.map(\.text) == ["Set it to 2.5 bar", "Then wait."])
    }

    @Test func compactSpikeFormStillParses() {
        let s = sentences(run(["Flip [[arrow:13:up]] it."]))
        #expect(s[0].cues.first?.cue == .move(mark: 13, direction: .up))
    }

    @Test func nonASCIIOffsetsAreUTF16() {
        let s = sentences(run(["Zet de schakelaar “aan” en [[outline m=1]] daarna de één."]))
        #expect(word(at: s[0].cues[0].anchor, in: s[0].text) == "daarna")
    }
}

@Suite struct CueStreamParserEdgeTests {
    @Test func tagAfterTheLastSentenceBindsToIt() {
        let events = run(["That is the one. [[outline at=500,500 obj=\"key\" text=\"esc\"]]"])
        let s = sentences(events)
        #expect(s.map(\.text) == ["That is the one."])
        #expect(s[0].cues.first?.cue == .outline(mark: 1))
        #expect(word(at: s[0].cues[0].anchor, in: s[0].text) == "one")
    }

    @Test func tagRightAfterATerminatorBelongsToTheNextSentence() {
        let s = sentences(run(["Hold alt gr.[[ring m=2 label=\"2\"]] Then press it."]))
        #expect(s.map(\.text) == ["Hold alt gr.", "Then press it."])
        #expect(s[0].cues.isEmpty)
        #expect(s[1].cues.first?.cue == .ring(mark: 2, label: "2"))
    }

    @Test func runawayTagIsNeverSpoken() {
        let long = String(repeating: "x", count: CueStreamParser.maxTagLength + 10)
        let s = sentences(run(["Look here. [[state seen=\"\(long)\"]] Then go on."]))
        #expect(s.map(\.text) == ["Look here.", "Then go on."])
    }

    @Test func targetsMergeOnlyForTheSameObject() {
        let events = run([
            "First [[ring at=200,500 obj=\"breaker\" text=\"C16\"]] this. ",
            "Then [[ring at=800,500 obj=\"breaker\" text=\"C16\"]] that. ",
            "And [[ring at=205,505 obj=\"breaker\" text=\"C16\"]] back. ",
            "Ctrl [[ring at=100,900 obj=\"key\" text=\"ctrl\"]] here, fn [[ring at=110,900 obj=\"key\" text=\"fn\"]] there.",
        ])
        let ids: [Int] = events.compactMap { if case .target(let id, _) = $0 { return id } else { return nil } }
        #expect(ids == [1, 2, 3, 4])
        let marks = sentences(events).flatMap { $0.cues.flatMap(\.cue.marks) }
        #expect(marks == [1, 2, 1, 3, 4])
    }

    @Test func rememberIsASideChannel() {
        let events = run(["Got it, a Mac. [[remember key=\"computer\" value=\"Mac\" from=said]]"])
        #expect(sentences(events).map(\.text) == ["Got it, a Mac."])
        #expect(events.contains(.sideChannel(.remember(key: "computer", value: "Mac", source: "said"), raw: "[[remember key=\"computer\" value=\"Mac\" from=said]]")))
    }

    @Test func taskIntentIsASideChannel() {
        let events = run(["I'll help you build it. [[task goal=\"assemble the wardrobe\" product=\"IKEA PAX\"]]"])
        #expect(events.contains(.sideChannel(.task(goal: "assemble the wardrobe", product: "IKEA PAX"), raw: "[[task goal=\"assemble the wardrobe\" product=\"IKEA PAX\"]]")))
    }

    @Test func landmarkRegistersATargetAndBindsToIt() {
        let events = run(["This is [[landmark at=400,600 obj=\"valve\" name=\"water stopcock\"]] the stopcock. I will remember it."])
        #expect(events.contains(.target(id: 1, spec: TargetSpec(x: 400, y: 600, phrase: "valve"))))
        #expect(sentences(events).first?.cues.first?.cue == .landmark(mark: 1, name: "water stopcock"))
    }

    @Test func rememberedPlacesArePointedAtByNumber() {
        let s = sentences(run(["It is over there [[outline m=900001]] under the sink."]))
        #expect(s.first?.cues.first?.cue == .outline(mark: 900001))
    }

    @Test func singleObjectCuesUseTheFirstPoint() {
        let events = run(["Press [[outline at=100,100;900,900 obj=\"button\"]] this."])
        let targets = events.filter { if case .target = $0 { return true } else { return false } }
        #expect(targets.count == 1)
        #expect(sentences(events).first?.cues.first?.cue == .outline(mark: 1))
    }
}

@Suite struct CueTagTests {
    @Test func parsesQuotedValuesAndLists() throws {
        let tag = CueTag.parse("danger m=11 reason=\"hot surface\"")
        #expect(tag?.attributes == ["m": "11", "reason": "hot surface"])
        #expect(try Cue.from(CueTag.parse("candidates m=3, 4")!).get() == .candidates(marks: [3, 4]))
        #expect(try Cue.from(CueTag.parse("candidates m=3,4")!).get() == .candidates(marks: [3, 4]))
        #expect(try Cue.from(CueTag.parse("rotate m=5 dir=ccw amount=half")!).get() == .rotate(mark: 5, direction: .ccw, amount: .half))
    }

    @Test func rejectsBadValues() {
        #expect((try? Cue.from(CueTag.parse("move m=1 dir=sideways")!).get()) == nil)
        #expect((try? Cue.from(CueTag.parse("locate x=1200 y=4")!).get()) == nil)
        #expect(CueTag.parse("outline m=") != nil)
        #expect(CueTag.parse("out-line m=1") == nil)
    }
}
