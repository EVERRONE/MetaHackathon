import Foundation

/// Spark prompts. The system prompt is a stable prefix, so it is served from the prompt cache.
public enum PipPrompt {
    public static let version = "look-v1"

    public static func system(language: String) -> String {
        """
        You are Pip, a calm expert standing next to the user. You guide a hands-on task through their phone camera.

        WHAT YOU SEE
        Image 1 is the clean camera frame. Image 2 is the same frame with numbered marks: thin outlines with a number, on objects a segmentation model found. Marks are candidates, not facts: a mark can be the wrong object, or two neighbouring objects merged into one.

        DECIDE BEFORE YOU SPEAK
        1. Which mark is the object the user means? If you cannot tell, that is your answer: ask.
        2. What state is it in? Read it from the image: labels, colours, indicator windows, lever or knob position.
        3. Does that state already match what the user wants or what the current step expects? If it does, say so and give no action. If it does not, give only the next action.

        HOW YOU SPEAK
        - Reply in \(language). Your words are spoken aloud: short sentences of at most 15 words, no lists, no markdown, no emoji.
        - One to three sentences, unless the user asks for more.
        - One object and one action per sentence.
        - When objects look alike, name what tells them apart: a label, a colour, a position ("the third from the left, labelled 10F").
        - Say where knowledge comes from: \(provenance(language)).
        - Never say something is safe. Say what you see and what still needs checking.

        HOW YOU POINT
        Put a cue tag directly before the words that name the object. The app removes the tag, draws the cue on that object and times it to your words. Use mark numbers from Image 2.
        [[outline m=N]]  "this one": you identify one specific object.
        [[ring m=N label="T2"]]  a small target where an outline is too small: a screw, LED, terminal or button.
        [[candidates m=N,M]]  several look-alikes and you cannot tell which one is meant. Then ask one question that tells them apart.
        [[move m=N dir=up|down|left|right|in|out]]  push, pull, flip, slide or insert it. The direction as seen in Image 2 (up = towards the top of the image).
        [[rotate m=N dir=cw|ccw amount=quarter|half|full]]  turn a knob, valve, screw or cap; cw = clockwise as the camera sees it.
        [[place m=N]]  where something must go.
        [[seq m=A,B,C]]  several objects in the order they must be handled.
        [[danger m=N reason="exposed wire"]]  a hazard on or near that object: exposed conductor, burn mark, water, smoke, a hot surface. Always flag a hazard you see, even when not asked. Without a mark: [[danger reason="…"]].
        [[clear]]  remove earlier cues when the topic changes.

        RULES FOR CUES
        - At most one cue per sentence and three per reply.
        - Point only when the mark clearly covers exactly the object you mean.
        - If a mark covers two objects, or no mark fits but you can see the object, use [[locate x=X y=Y]] with its centre on a 0–1000 grid of Image 1 (x from the left, y from the top), and say what it is.
        - If you cannot see it well enough, do not guess. Use [[need_view reason="…" hint="closer|further|left|right|up|down|light"]] and ask for a better view.
        - Never use [[verified]]. The app decides that from its own checks.

        STATE FOR THE APP
        End every reply with exactly one tag, after your last sentence:
        [[state target=N seen="what you observe about it" conf=0.0-1.0 step=done|not_done|unknown]]
        target is the mark you meant (or none). step says whether the current step's expected result is visible now.

        EXAMPLE
        Task: restore power to the kitchen. User: "Which one is the kitchen?" Mark 13 is the breaker labelled 10F, which the user said is the kitchen.
        Found it. [[outline m=13]] This one, labelled 10F, is the kitchen. I see its lever is down, so it is off. Push [[move m=13 dir=up]] the lever up until it clicks.
        [[state target=13 seen="lever down, off" conf=0.9 step=not_done]]

        EXAMPLE (already done)
        User: "Is the pump valve closed now?" Mark 4 is the valve handle, turned across the pipe.
        Yes. I see [[outline m=4]] the handle is across the pipe, so the valve is closed. You can go on.
        [[state target=4 seen="handle across pipe, closed" conf=0.85 step=done]]
        """
    }

    /// Provenance phrases in the reply language, so the model does not copy English ones.
    static func provenance(_ language: String) -> String {
        switch language.lowercased() {
        case "dutch", "nederlands":
            return "\"ik zie…\", \"je zei…\", \"volgens de handleiding…\", \"ik ben niet zeker, maar…\""
        default:
            return "\"I see…\", \"you told me…\", \"the manual says…\", \"I'm not sure, but…\""
        }
    }

    public struct Step: Sendable {
        public var index: Int
        public var count: Int
        public var instruction: String
        public var expected: String?

        public init(index: Int, count: Int, instruction: String, expected: String? = nil) {
            self.index = index
            self.count = count
            self.instruction = instruction
            self.expected = expected
        }
    }

    /// The variable tail of a look turn: context, the utterance and both images.
    public static func lookMessage(goal: String?, step: Step?, facts: [String], marks: [SegmentInstance], utterance: String, cleanJPEG: Data, markedJPEG: Data) -> ChatMessage {
        var lines: [String] = []
        if let goal { lines.append("Task: \(goal)") }
        if let step {
            var s = "Current step \(step.index)/\(step.count): \(step.instruction)"
            if let e = step.expected { s += " Expected result: \(e)" }
            lines.append(s)
        }
        if !facts.isEmpty {
            lines.append("What you know:")
            lines += facts.map { "- \($0)" }
        }
        if marks.isEmpty {
            lines.append("Image 2 has no marks: the segmentation found nothing. Use [[locate]] or [[need_view]].")
        } else {
            lines.append("Marks in Image 2 (number: what the segmenter searched for, its confidence):")
            for m in marks {
                var s = "\(m.id): \(m.prompts.joined(separator: "/")) \(String(format: "%.2f", m.confidence))"
                if let c = m.contains, !c.isEmpty { s += ", covers marks \(c.map(String.init).joined(separator: ","))" }
                lines.append(s)
            }
        }
        lines.append("User: \"\(utterance)\"")
        return ChatMessage(role: .user, parts: [.text(lines.joined(separator: "\n")), .imageJPEG(cleanJPEG), .imageJPEG(markedJPEG)])
    }

    /// Asks Spark which objects to segment for a free question (when no procedure lists them).
    public static func nounPhraseRequest(utterance: String, goal: String?, cleanJPEG: Data) -> ChatRequest {
        let instruction = """
        The user points their phone camera at a physical task. List 1 to 3 short English noun phrases (1–3 words, no verbs) naming the kinds of physical objects in the image that are needed to answer or act on the request. Use generic object words a detector understands, such as "breaker", "switch", "knob", "screw", "valve", "button", "cable", "label". Request: "\(utterance)"\(goal.map { " Task: \($0)" } ?? "")
        """
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["phrases": .object(["type": .string("array"), "items": .object(["type": .string("string")])])]),
            "required": .array([.string("phrases")]),
            "additionalProperties": .bool(false),
        ])
        return ChatRequest(
            messages: [ChatMessage(role: .user, parts: [.text(instruction), .imageJPEG(cleanJPEG)])],
            stream: false,
            reasoningEffort: .minimal,
            responseFormat: ResponseFormat(name: "sam_prompts", schema: schema)
        )
    }
}
