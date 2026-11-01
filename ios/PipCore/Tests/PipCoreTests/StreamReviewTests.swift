import CoreGraphics
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

    @Test func anErrorSentMidStreamCutsTheAnswerOff() async {
        let body = Self.chunk("Press it once. And then the") + "data: {\"error\":{\"message\":\"overloaded\"}}\n\n"
        let (said, failed) = await Self.look(body, breakOff: false)
        #expect(said.map { $0.trimmingCharacters(in: .whitespaces) } == ["Press it once."])
        #expect(failed)
    }
}
