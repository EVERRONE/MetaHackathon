import CoreGraphics
import simd
import Foundation
import Testing
@testable import PipCore

/// Findings of the code review of 1 Nov on answers that break off, braces in the model's
/// narration and an outline at the edge of the frame: each was reproduced first, then fixed.
@Suite(.serialized) struct StreamReviewTests {
    struct Answer: Decodable, Equatable { var found: Bool }

    @Test func theAnswerIsFoundPastBracesInTheNarration() {
        #expect(ProcedureCompiler.answer(Answer.self, in: ["Searching for {model} manuals…", #"Here it is: {"found":true}"#]) == Answer(found: true))
        #expect(ProcedureCompiler.answer(Answer.self, in: [#"Use {this} form: {"found":false} done"#]) == Answer(found: false))
        // The last message answers.
        #expect(ProcedureCompiler.answer(Answer.self, in: [#"{"found":true}"#, #"{"found":false}"#]) == Answer(found: false))
        #expect(ProcedureCompiler.answer(Answer.self, in: ["no answer {"]) == nil)
    }

    @Test func anErrorInTheStreamIsRead() {
        let d = ChatChunkDecoder()
        #expect(d.error(forLine: #"data: {"error":{"message":"overloaded","code":"503"}}"#) == "overloaded")
        #expect(d.error(forLine: #"data: {"choices":[{"delta":{"content":"hi"}}]}"#) == nil)
        #expect(d.error(forLine: "data: [DONE]") == nil)
    }

    static func frame(width: Int = 640, height: Int = 480) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    @Test func aBoxJustOutsideTheFrameIsNotRegrounded() async {
        // Its padded region reaches into the frame, the box itself does not: this used to trap
        // (an integer from an infinite coordinate) before any request was made.
        let grounder = Grounder(client: PipClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: ""), frameJPEG: Data())
        let found = await grounder.reground(box: CGRect(x: -110, y: 100, width: 100, height: 50), id: 1, frame: Self.frame())
        #expect(found == nil)
    }

    /// Serves /v1/chat as a stream that breaks off after `StreamStub.body`.
    final class StreamStub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var body = ""
        nonisolated(unsafe) static var breakOff = true
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard request.url?.path.hasSuffix("/v1/chat") == true else {
                // Grounding is slow here and fails: a sentence waits for its mark meanwhile.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { [self] in
                    let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data(#"{"error":{"code":"upstream","message":"busy"}}"#.utf8))
                    client?.urlProtocolDidFinishLoading(self)
                }
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
            // The connection drops a moment after the last bytes, as on a real network.
            let breakOff = Self.breakOff
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
                if breakOff { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) } else { client?.urlProtocolDidFinishLoading(self) }
            }
        }
        override func stopLoading() {}
    }

    static func chunk(_ text: String) -> String {
        let escaped = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
        return "data: {\"choices\":[{\"delta\":{\"content\":\(escaped)}}]}\n\n"
    }

    static func look(_ body: String, breakOff: Bool) async -> (said: [String], failed: Bool) {
        StreamStub.body = body
        StreamStub.breakOff = breakOff
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamStub.self]
        let client = PipClient(baseURL: URL(string: "https://pip.test")!, token: "t", session: URLSession(configuration: config))
        var said: [String] = []
        do {
            var pipeline = LookPipeline(client: client)
            pipeline.groundingTimeout = 1.5
            for try await event in pipeline.run(LookRequest(frame: frame(), utterance: "where is the power button?")) {
                if case .sentence(let s, _) = event { said.append(s.text) }
            }
            return (said, false)
        } catch {
            return (said, true)
        }
    }

    @Test func sentencesThatCameWholeAreSaidWhenTheStreamBreaksOff() async {
        // The second sentence waits for its mark when the connection drops: it used to be lost.
        let body = Self.chunk("The power button is on the left. ") + Self.chunk("Press [[ring at=500,500 obj=\"button\"]] this one. And then the")
        let (said, failed) = await Self.look(body, breakOff: true)
        #expect(said.map { $0.trimmingCharacters(in: .whitespaces) } == ["The power button is on the left.", "Press this one."], "\(said)")
        #expect(failed)
    }

    @Test func aWarningIsSaidWithoutWaitingForItsMark() async throws {
        // Grounding takes 0.8 s here: the warning comes before its mark, not after.
        StreamStub.body = Self.chunk("Careful [[danger at=500,500 obj=\"wire\" reason=\"bare wire\"]] there. ")
        StreamStub.breakOff = false
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamStub.self]
        let client = PipClient(baseURL: URL(string: "https://pip.test")!, token: "t", session: URLSession(configuration: config))
        var order: [String] = []
        for try await event in LookPipeline(client: client).run(LookRequest(frame: Self.frame(), utterance: "is this safe?")) {
            if case .sentence = event { order.append("sentence") }
            if case .grounded = event { order.append("grounded") }
        }
        #expect(order.first == "sentence", "\(order)")
    }

    @Test func anErrorSentMidStreamCutsTheAnswerOff() async {
        let body = Self.chunk("Press it once. And then the") + "data: {\"error\":{\"message\":\"overloaded\"}}\n\n"
        let (said, failed) = await Self.look(body, breakOff: false)
        #expect(said.map { $0.trimmingCharacters(in: .whitespaces) } == ["Press it once."])
        #expect(failed)
    }
}

/// The rest of the PipCore review of 1 Nov: tags, binding to symbols, warnings, gas work.
@Suite struct CueReviewTests {
    static func run(_ chunks: [String]) -> [CueStreamEvent] {
        var parser = CueStreamParser()
        var events: [CueStreamEvent] = []
        for c in chunks { events += parser.feed(c) }
        events += parser.finish()
        return events
    }

    static func sentences(_ events: [CueStreamEvent]) -> [SpokenSentence] {
        events.compactMap { if case .sentence(let s) = $0 { return s } else { return nil } }
    }

    @Test func aCueBeforeASymbolIsOnTheSymbol() {
        for (said, symbol) in [("Press [[ring at=500,500 obj=\"key\" text=\"@\"]] @ now.", "@"), ("Hold [[ring at=500,500 obj=\"key\" text=\"⌘\"]] ⌘ and space.", "⌘")] {
            let s = Self.sentences(Self.run([said]))
            let text = s.first?.text ?? ""
            let anchor = s.first?.cues.first?.anchor ?? -1
            let offset = text.utf16.distance(from: text.utf16.startIndex, to: text.range(of: symbol)!.lowerBound.samePosition(in: text.utf16)!)
            #expect(anchor == offset, "\(said)")
        }
    }

    @Test func spacedListsAndTypographicQuotesAreRead() {
        #expect(CueTag.parse("candidates at=100,200; 300,400 obj=\"key\"")?.attributes["at"] == "100,200;300,400")
        #expect(CueTag.parse("ring at=1,2 obj=”key”")?.attributes["obj"] == "key")
        #expect(CueTag.parse("ring at=1,2 obj=„key“")?.attributes["obj"] == "key")
        #expect(CueTag.parse("ring at=1,2 obj=„key”")?.attributes["obj"] == "key")
        #expect(CueTag.parse("ring at=1,2 text=‘F1’")?.attributes["text"] == "F1")
        // A list of several points with a space after ";" names two targets.
        let events = Self.run(["These [[candidates at=100,200; 300,400 obj=\"knob\"]] two."])
        #expect(events.filter { if case .target = $0 { return true } else { return false } }.count == 2)
    }

    @Test func aCueThatWillBeDroppedIsNotGrounded() {
        let events = Self.run(["Move [[move at=500,500 obj=\"lever\" dir=sideways]] it."])
        #expect(!events.contains { if case .target = $0 { return true } else { return false } })
        #expect(events.contains { if case .invalidTag = $0 { return true } else { return false } })
    }

    @Test func gasAndMainsWorkInAnyWordOrder() {
        for goal in ["sluit het gasfornuis aan", "open de gasketel", "connect the gas stove"] {
            #expect(SafetyPolicy.classify(goal) == .refused(reason: "gas"), "\(goal)")
        }
        for goal in ["plafondlamp ophangen", "stopcontact verplaatsen", "fit a new light switch"] {
            #expect(SafetyPolicy.classify(goal) == .refused(reason: "mains"), "\(goal)")
        }
        #expect(SafetyPolicy.classify("treat my wounds") == .refused(reason: "medical"))
        #expect(SafetyPolicy.classify("de druk van de gasketel controleren") == .allowedWithGates)
        // Still allowed.
        #expect(SafetyPolicy.classify("hang a picture") == .allowed)
        #expect(SafetyPolicy.classify("change the battery of the smoke alarm") == .allowed)
    }
}

/// One picture of an object carries every key on it (1 Nov: three pictures of one keyboard,
/// one per key, were never found by ARKit).
@Suite struct ObjectFaceTests {
    static func key(_ x: Int, _ y: Int, id: Int) -> SegmentInstance {
        SegmentInstance(id: id, prompts: ["key"], confidence: 0.9, box: [x, y, x + 30, y + 30], area: 900, centroid: [x + 15, y + 15],
                        polygons: [[x, y, x + 30, y, x + 30, y + 30, x, y + 30]])
    }

    @Test func keysOnOneObjectShareOneFace() throws {
        let image = StreamReviewTests.frame(width: 1000, height: 800)
        let keyboard = SegmentInstance(id: 9, prompts: ["keyboard"], confidence: 0.9, box: [100, 200, 900, 600], area: 320_000, centroid: [500, 400],
                                       polygons: [[100, 200, 900, 200, 900, 600, 100, 600]])
        let keys = [Self.key(300, 400, id: 1), Self.key(420, 380, id: 2), Self.key(330, 330, id: 3)]
        let made = try #require(ObjectFace.make(keys: keys, object: keyboard, image: image, focal: 1000, distance: 0.3))
        #expect(made.locals.count == 3)
        // Every key's outline lies in the one picture, apart as on the keyboard: 120 px is 3.6 cm at 0.3 m.
        let centres = made.locals.map { rings -> simd_float3 in let pts = rings.flatMap { $0 }; return pts.reduce(.zero, +) / Float(pts.count) }
        #expect(abs((centres[1].x - centres[0].x) - 0.036) < 0.002)
        #expect(abs(made.physicalWidth - CGFloat(made.image.width) * 0.3 / 1000) < 0.001)
        // The single-key face is still the first key's.
        let one = try #require(ObjectFace.make(key: keys[0], object: keyboard, image: image, focal: 1000, distance: 0.3))
        #expect(one.locals.count == 1)
    }
}

@Suite struct FreshStartTests {
    @Test func aFreshStartKeepsTheCuesOfObjectsFoundAgain() {
        var board = AnnotationBoard()
        board.show(.ring(mark: 1001, label: "1"), at: 0)
        board.show(.ring(mark: 1002, label: "2"), at: 0)
        board.show(.outline(mark: 900_001), at: 0)
        board.show(.danger(mark: nil, reason: "hot"), at: 0)
        board.keep(marks: [1001, 1002])
        #expect(Set(board.annotations.flatMap(\.cue.marks)) == [1001, 1002])
        // A hazard stays until it is resolved.
        #expect(board.annotations.contains { if case .danger = $0.cue { return true } else { return false } })
    }
}
