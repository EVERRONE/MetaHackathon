import Foundation
import Testing
@testable import PipCore

/// Looking a fact up: the tag, reading the search's answer, and which page Pip names as its source.
@Suite struct WebLookupTests {
    @Test func theTagCarriesTheQuestion() throws {
        let tag = try #require(CueTag.parse(#"lookup q="Korvo CM-210: what does a blinking orange light mean?""#))
        #expect(try Cue.from(tag).get() == .lookup(query: "Korvo CM-210: what does a blinking orange light mean?"))
        #expect(!Cue.lookup(query: "x").isDrawn)
        let bare = try #require(CueTag.parse("lookup"))
        #expect((try? Cue.from(bare).get()) == nil)
    }

    @Test func theTagComesThroughTheParserAsASideChannel() {
        var parser = CueStreamParser()
        let events = parser.feed("I'll look that up.\n[[state seen=\"light\" conf=0.4 step=unknown]]\n[[lookup q=\"Korvo CM-210 orange light\"]]\n") + parser.finish()
        let side = events.compactMap { e -> Cue? in if case .sideChannel(let c, _) = e { return c } else { return nil } }
        #expect(side.contains(.lookup(query: "Korvo CM-210 orange light")))
    }

    /// The shape Meta's Responses API answered with on 1 Nov: narration between searches, the
    /// JSON last, citations on it, and the pages the tool opened.
    static let response = """
    {"output": [
      {"type": "reasoning", "id": "rs_1"},
      {"type": "message", "content": [{"type": "output_text", "text": "Ik zoek het op in de handleiding."}]},
      {"type": "web_search_call", "status": "completed", "action": {"type": "search", "query": "Korvo CM-210 orange light"}},
      {"type": "web_search_call", "status": "completed", "action": {"type": "open_page", "url": "https://support.korvo.example/cm210/manual.pdf"}},
      {"type": "web_search_call", "status": "failed", "action": {"type": "open_page", "url": "https://manualslib.example/korvo"}},
      {"type": "message", "content": [{"type": "output_text",
        "text": "{\\"found\\": true, \\"answer\\": \\"Het oranje lampje knippert: ontkalken.\\", \\"sources\\": [{\\"title\\": \\"Manual\\", \\"url\\": \\"https://support.korvo.example/cm210/manual.pdf\\", \\"publisher\\": \\"Korvo\\", \\"official\\": true}]}",
        "annotations": [{"type": "url_citation", "url": "https://support.korvo.example/cm210/manual.pdf", "start_index": 0, "end_index": 10, "title": "x"}]}]}
    ]}
    """

    @Test func theAnswerIsTheLastMessageAndItsSourceIsReal() throws {
        let output = try PipClient.ResponsesOutput.decode(Data(Self.response.utf8))
        #expect(output.texts.count == 2)
        #expect(output.searches == 3)
        // A page the tool failed to open is not evidence of anything.
        #expect(output.citations == ["https://support.korvo.example/cm210/manual.pdf"])
        let a = try WebLookup.read(output)
        #expect(a.found)
        #expect(a.answer == "Het oranje lampje knippert: ontkalken.")
        #expect(a.best?.publisher == "Korvo")
        #expect(a.official)
        #expect(a.best?.isPDF == true)
    }

    @Test func aSourceTheSearchNeverOpenedIsNotNamed() {
        let made = WebLookup.Source(title: "T", url: "https://korvo.example/made-up", publisher: "Korvo", official: true)
        let a = WebLookup.Answer(found: true, answer: "x", sources: [made], cited: ["https://elsewhere.example/page"])
        #expect(a.best == nil)
        #expect(!a.official)
    }

    @Test func theManufacturerComesBeforeAMirrorSite() {
        let mirror = WebLookup.Source(title: "M", url: "https://www.manualslib.com/korvo.html", publisher: "ManualsLib", official: false)
        let blog = WebLookup.Source(title: "B", url: "https://coffee.example/tips", publisher: "Coffee blog", official: false)
        let maker = WebLookup.Source(title: "K", url: "https://korvo.example/support/", publisher: "Korvo", official: true)
        let cited = ["https://manualslib.com/korvo.html", "https://coffee.example/tips", "https://www.korvo.example/support#lights"]
        #expect(WebLookup.Answer(found: true, answer: "x", sources: [mirror, blog, maker], cited: cited).best == maker)
        #expect(WebLookup.Answer(found: true, answer: "x", sources: [mirror, blog], cited: cited).best == blog)
        // Only a mirror: named, but never as official.
        let onlyMirror = WebLookup.Answer(found: true, answer: "x", sources: [WebLookup.Source(title: "M", url: mirror.url, publisher: "Korvo", official: true)], cited: cited)
        #expect(onlyMirror.best != nil)
        #expect(!onlyMirror.official)
    }

    @Test func nothingFoundOrAnEmptyAnswerIsNotFound() throws {
        let none = PipClient.ResponsesOutput(texts: [#"{"found": false, "answer": "De handleiding noemt dit niet.", "sources": []}"#], citations: [], searches: 2)
        #expect(try !WebLookup.read(none).found)
        let empty = PipClient.ResponsesOutput(texts: [#"{"found": true, "answer": " ", "sources": []}"#], citations: [], searches: 1)
        #expect(try !WebLookup.read(empty).found)
        let garbage = PipClient.ResponsesOutput(texts: ["Sorry."], citations: [], searches: 0)
        #expect(throws: WebLookup.LookupError.self) { try WebLookup.read(garbage) }
    }

    @Test func theTaskReportListsWhatWasLookedUp() throws {
        let procedure = try ProcedureSourceTests.raw(sources: []).compiled(goal: "g", source: .none, seconds: 1).procedure
        var log = SessionLog()
        log.add(.lookedUp, step: 0, "silk setting → stand 1 (https://korvo.example/manual.pdf)")
        let report = log.report(for: ProcedureRuntime(procedure: procedure))
        #expect(report.contains("Looked up at step 1: silk setting → stand 1"))
    }
}
