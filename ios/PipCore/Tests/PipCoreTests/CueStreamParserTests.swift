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
