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
        public enum Problem: String, Equatable, Sendable {
            case none
            /// The user acts on the wrong object or part.
            case wrongObject = "wrong_object"
            /// Something is the wrong way round or in the wrong place.
            case wrongWay = "wrong_way"
            /// A later step is being done before this one.
            case wrongOrder = "wrong_order"
            /// Something unsafe: exposed conductor, water near electricity, smoke, an unsecured heavy part.
            case hazard
        }

        public var done: Bool
        public var confidence: Double
        public var seen: String
        public var problem: Problem
        /// What is going wrong, in a few words, for Pip to correct.
        public var problemText: String
        public var problemConfidence: Double
    }

    /// What the check knows about the step.
    public struct StepContext: Sendable {
        public var instruction: String
        public var expected: String
        public var cautions: [String]
        public var nextInstruction: String?

        public init(instruction: String, expected: String, cautions: [String] = [], nextInstruction: String? = nil) {
            self.instruction = instruction
            self.expected = expected
            self.cautions = cautions
            self.nextInstruction = nextInstruction
        }
    }

    /// `focus` is the work area in frame pixels (the step's objects); nil looks at the whole frame.
    public func check(_ frame: CGImage, step: StepContext, focus: CGRect?) async throws -> Result {
        var image = frame
        if let focus {
            let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            let pad = max(focus.width, focus.height) * 0.8 + 40
            let area = focus.insetBy(dx: -pad, dy: -pad).intersection(bounds).integral
            if area.width > 32, area.height > 32, let crop = SetOfMarks.crop(frame, to: area, scale: min(2, 768 / max(area.width, area.height))) {
                image = crop
            }
        }
        guard let jpeg = SetOfMarks.resize(image, maxSide: 768).flatMap({ SetOfMarks.jpeg($0, quality: 0.75) }) else {
            return Result(done: false, confidence: 0, seen: "", problem: .none, problemText: "", problemConfidence: 0)
        }
        let question = """
        Someone is doing a hands-on task, step by step. You watch over their shoulder.
        The current step: "\(step.instruction)"
        It is done when this is clearly visible: "\(step.expected)"
        \(step.cautions.isEmpty ? "" : "Cautions: \(step.cautions.joined(separator: "; "))\n")\(step.nextInstruction.map { "The step after it: \"\($0)\"\n" } ?? "")
        1. done: true only if you clearly see the result now; partly there, hidden, blurry or unsure means false.
        2. problem: is something clearly going wrong right now? wrong_object (the wrong part, screw, breaker or key is being used), wrong_way (upside down, reversed, in the wrong place), wrong_order (they are doing a later step first), hazard (exposed conductor, water near electricity, smoke, an unsecured heavy part). Only report what you clearly see; normal work in progress is none.
        seen and problem_text: a few words each; problem_text is empty when problem is none.
        """
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "done": .object(["type": .string("boolean")]),
                "confidence": .object(["type": .string("number")]),
                "seen": .object(["type": .string("string")]),
                "problem": .object(["type": .string("string"), "enum": .array(["none", "wrong_object", "wrong_way", "wrong_order", "hazard"].map { .string($0) })]),
                "problem_text": .object(["type": .string("string")]),
                "problem_confidence": .object(["type": .string("number")]),
            ]),
            "required": .array(["done", "confidence", "seen", "problem", "problem_text", "problem_confidence"].map { .string($0) }),
            "additionalProperties": .bool(false),
        ])
        var request = ChatRequest(messages: [ChatMessage(role: .user, parts: [.text(question), .imageJPEG(jpeg)])], stream: false,
                                  reasoningEffort: .minimal, responseFormat: ResponseFormat(name: "step_check", schema: schema))
        request.model = model
        let (text, _) = try await client.chat(request)
        struct Out: Decodable {
            var done: Bool; var confidence: Double; var seen: String
            var problem: String; var problem_text: String; var problem_confidence: Double
        }
        let out = try JSONDecoder().decode(Out.self, from: Data(text.utf8))
        return Result(done: out.done, confidence: max(0, min(1, out.confidence)), seen: out.seen,
                      problem: Result.Problem(rawValue: out.problem) ?? .none, problemText: out.problem_text,
                      problemConfidence: max(0, min(1, out.problem_confidence)))
    }
}
