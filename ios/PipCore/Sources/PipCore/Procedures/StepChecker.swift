import CoreGraphics
import Foundation

/// Watching mode: a quick look at whether a step's expected result is visible, so Pip notices on
/// its own that the user has done the step. Spark at the lowest effort on a crop of the work area
/// keeps each check fast and cheap; the caller requires two positive checks in a row.
public struct StepChecker: Sendable {
    public var client: PipClient
    public var model = "muse-spark-1.3"

    public init(client: PipClient) {
        self.client = client
    }

    public struct Result: Equatable, Sendable {
        public var done: Bool
        public var confidence: Double
        public var seen: String
    }

    /// `focus` is the work area in frame pixels (the step's objects); nil looks at the whole frame.
    public func check(_ frame: CGImage, expected: String, focus: CGRect?) async throws -> Result {
        var image = frame
        if let focus {
            let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            let pad = max(focus.width, focus.height) * 0.8 + 40
            let area = focus.insetBy(dx: -pad, dy: -pad).intersection(bounds).integral
            if area.width > 32, area.height > 32, let crop = SetOfMarks.crop(frame, to: area, scale: min(2, 768 / max(area.width, area.height))) {
                image = crop
            }
        }
        guard let jpeg = SetOfMarks.resize(image, maxSide: 768).flatMap({ SetOfMarks.jpeg($0, quality: 0.75) }) else { return Result(done: false, confidence: 0, seen: "") }
        let question = """
        Someone is doing a hands-on task. Look at the image and decide whether this is clearly visible now: "\(expected)".
        Answer done=true only if you clearly see it; if it is partly there, hidden, blurry or you are unsure, done=false. seen: what you observe, in a few words.
        """
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "done": .object(["type": .string("boolean")]),
                "confidence": .object(["type": .string("number")]),
                "seen": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("done"), .string("confidence"), .string("seen")]),
            "additionalProperties": .bool(false),
        ])
        var request = ChatRequest(messages: [ChatMessage(role: .user, parts: [.text(question), .imageJPEG(jpeg)])], stream: false,
                                  reasoningEffort: .minimal, responseFormat: ResponseFormat(name: "step_check", schema: schema))
        request.model = model
        let (text, _) = try await client.chat(request)
        struct Out: Decodable { var done: Bool; var confidence: Double; var seen: String }
        let out = try JSONDecoder().decode(Out.self, from: Data(text.utf8))
        return Result(done: out.done, confidence: max(0, min(1, out.confidence)), seen: out.seen)
    }
}
