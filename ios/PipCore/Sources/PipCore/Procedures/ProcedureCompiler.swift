import Foundation

/// An official document for a product, found on the web and checked to exist.
public struct ManualReference: Codable, Equatable, Sendable {
    public var title: String
    public var publisher: String
    public var url: String
    public var pageURL: String?
}

/// Builds procedures: finds the official manual for a product on the web, then compiles the
/// step-by-step plan from that manual, from the user's photos or text, or from general knowledge
/// (then marked as not from a verified source).
public struct ProcedureCompiler: Sendable {
    public var client: PipClient
    public var language: String
    public var finderModel = "muse-spark-1.3"
    public var compilerModel = "muse-wonder-1.0"

    public init(client: PipClient, language: String) {
        self.client = client
        self.language = language
    }

    public enum SourceInput: Sendable {
        case manual(ManualReference)
        case images([Data])
        case text(String)
        case none
    }

    public struct Compiled: Sendable {
        public var procedure: Procedure
        public var classification: SafetyPolicy.Classification
        /// The camera shows a different device than the source describes.
        public var mismatch: String?
        public var seconds: Double
    }

    // MARK: Finding the manual

    /// Mirror sites copy manuals without guarantee that they are complete or current.
    static let unofficialHosts = ["manuals.plus", "device.report", "manualslib", "manualzz", "usermanual.wiki", "scribd", "pdfcoffee", "issuu"]

    public func findManual(for product: String) async throws -> ManualReference? {
        let prompt = """
        Find the official assembly instructions, installation guide or user manual for: \(product).
        Use only the manufacturer's own website, never mirror or manual-collection sites. I need the direct link to the PDF file.
        Reply with JSON only: {"found": true|false, "title": "...", "publisher": "...", "pdf_url": "https://... or empty", "page_url": "https://... or empty"}
        """
        let body: JSONValue = .object([
            "model": .string(finderModel),
            "input": .string(prompt),
            "tools": .array([.object(["type": .string("web_search")])]),
            "reasoning": .object(["effort": .string("low")]),
        ])
        let text = try await client.responsesText(body)
        struct Found: Decodable { var found: Bool?; var title: String?; var publisher: String?; var pdf_url: String?; var page_url: String? }
        guard let json = Self.firstJSONObject(in: text), let found = try? JSONDecoder().decode(Found.self, from: Data(json.utf8)),
              found.found == true, let url = found.pdf_url, !url.isEmpty else { return nil }
        guard let host = URL(string: url)?.host?.lowercased(), !Self.unofficialHosts.contains(where: { host.contains($0) }) else { return nil }
        // Models can produce a link that looks right but does not exist.
        guard try await client.sourceCheck(url) else { return nil }
        return ManualReference(title: found.title ?? product, publisher: found.publisher ?? host, url: url, pageURL: found.page_url)
    }

    // MARK: Compiling

    public func compile(goal: String, source: SourceInput, frameJPEG: Data?, facts: [String]) async throws -> Compiled {
        let t0 = Date()
        var content: [JSONValue] = [.object(["type": .string("input_text"), "text": .string(instructions(goal: goal, source: source, facts: facts))])]
        switch source {
        case .manual(let m):
            content.append(.object(["type": .string("input_file"), "file_url": .string(m.url)]))
        case .images(let pages):
            for p in pages { content.append(.object(["type": .string("input_image"), "image_url": .string("data:image/jpeg;base64," + p.base64EncodedString())])) }
        case .text(let t):
            content.append(.object(["type": .string("input_text"), "text": .string("SOURCE TEXT:\n" + t)]))
        case .none:
            break
        }
        if let frameJPEG {
            content.append(.object(["type": .string("input_text"), "text": .string("The user's camera view right now:")]))
            content.append(.object(["type": .string("input_image"), "image_url": .string("data:image/jpeg;base64," + frameJPEG.base64EncodedString())]))
        }
        let body: JSONValue = .object([
            "model": .string(compilerModel),
            "input": .array([.object(["role": .string("user"), "content": .array(content)])]),
            "reasoning": .object(["effort": .string("low")]),
            "text": .object(["format": .object([
                "type": .string("json_schema"), "name": .string("procedure"), "strict": .bool(true), "schema": Self.schema,
            ])]),
        ])
        let text = try await client.responsesText(body)
        guard let json = Self.firstJSONObject(in: text) else { throw CompilerError.unreadable(String(text.prefix(200))) }
        let raw = try JSONDecoder().decode(RawProcedure.self, from: Data(json.utf8))
        return try raw.compiled(goal: goal, source: source, seconds: Date().timeIntervalSince(t0))
    }

    func instructions(goal: String, source: SourceInput, facts: [String]) -> String {
        let sourceLine: String
        switch source {
        case .manual(let m): sourceLine = "The attached PDF is the official document from \(m.publisher): \(m.title). Base every step on it and give its page number as source_ref."
        case .images: sourceLine = "The attached photos are the user's instructions. Base every step on them and give the photo number as source_ref (\"photo 1\")."
        case .text: sourceLine = "The SOURCE TEXT is the user's instructions. Base every step on it; source_ref quotes a few words of it."
        case .none: sourceLine = "There is no source. Draft the procedure from general knowledge, conservatively; source_ref is empty. It will be marked as not from a verified source."
        }
        return """
        You write a guided procedure for Pip, an assistant that guides someone through a hands-on task with their phone camera, one step at a time, and checks each step on camera.
        The user's goal: \(goal)
        \(sourceLine)
        \(facts.isEmpty ? "" : "What is known about the user's situation:\n" + facts.map { "- \($0)" }.joined(separator: "\n"))

        Rules:
        - Write in \(language). Steps are short, one action each, at most 15 steps; merge tiny actions.
        - objects: the physical things the steps act on, with a short id, a name, phrase (a generic 1–2 word English noun a detector understands: "panel", "screw", "knob", "breaker") and the text printed on it, if any.
        - For each step: targets (object ids), and check: camera when the result can be seen on camera (expected says concretely what is visible: "4 bolts stick out of each side panel"); user when only the user can tell ("the lights work again"); none when nobody can check it here (a torque, a voltage).
        - gate: a safety condition the user must confirm before that step, only where it matters ("the power to the circuit is switched off", "two people hold the frame"); empty otherwise.
        - cautions: warnings that matter for the whole task; why: a few words on why a step matters, or empty.
        - classification: refused for medical tasks, gas work, work on mains wiring behind covers, and structural work (then refusal_reason says why, and steps may be empty); allowed_with_gates for electrical panels, boilers, lifts and work at height; otherwise allowed.
        - Compare the camera view with the source: if it clearly shows a different model or product, say so in mismatch; otherwise mismatch is empty.
        """
    }

    struct RawProcedure: Decodable {
        struct RawObject: Decodable { var id: String; var name: String; var phrase: String; var text: [String] }
        struct RawStep: Decodable {
            var instruction: String; var why: String; var targets: [String]
            var check_kind: String; var expected: String; var cautions: [String]; var gate: String; var source_ref: String
        }
        var title: String
        var classification: String
        var refusal_reason: String
        var objects: [RawObject]
        var steps: [RawStep]
        var cautions: [String]
        var mismatch: String

        func compiled(goal: String, source: SourceInput, seconds: Double) throws -> Compiled {
            let src: Procedure.Source
            switch source {
            case .manual(let m): src = .init(kind: .pdf, reference: "\(m.publisher): \(m.title) (\(m.url))")
            case .images(let p): src = .init(kind: .images, reference: "\(p.count) photo(s) of the instructions")
            case .text: src = .init(kind: .text, reference: "the user's text")
            case .none: src = .init(kind: .none)
            }
            let procedure = Procedure(
                title: title, goal: goal, source: src,
                objects: objects.map { .init(id: $0.id, name: $0.name, phrase: $0.phrase, text: $0.text) },
                steps: steps.enumerated().map { i, s in
                    Procedure.Step(id: String(i + 1), instruction: s.instruction, why: s.why.isEmpty ? nil : s.why, targets: s.targets,
                                   check: .init(kind: Procedure.Check.Kind(rawValue: s.check_kind) ?? .user, expected: s.expected),
                                   cautions: s.cautions, gate: s.gate.isEmpty ? nil : s.gate, sourceRef: s.source_ref.isEmpty ? nil : s.source_ref)
                },
                cautions: cautions)
            let modelClass: SafetyPolicy.Classification
            switch classification {
            case "refused": modelClass = .refused(reason: refusal_reason.isEmpty ? "professional" : refusal_reason)
            case "allowed_with_gates": modelClass = .allowedWithGates
            default: modelClass = .allowed
            }
            // The code's own rules win over the model's when they are stricter.
            let codeClass = SafetyPolicy.classify(goal)
            let final: SafetyPolicy.Classification
            switch (codeClass, modelClass) {
            case (.refused, _): final = codeClass
            case (_, .refused): final = modelClass
            case (.allowedWithGates, _), (_, .allowedWithGates): final = .allowedWithGates
            default: final = .allowed
            }
            if case .refused = final {} else {
                let problems = procedure.problems()
                if !problems.isEmpty { throw CompilerError.invalid(problems) }
            }
            return Compiled(procedure: procedure, classification: final, mismatch: mismatch.isEmpty ? nil : mismatch, seconds: seconds)
        }
    }

    static let schema: JSONValue = {
        func str() -> JSONValue { .object(["type": .string("string")]) }
        func arr(_ items: JSONValue) -> JSONValue { .object(["type": .string("array"), "items": items]) }
        func obj(_ props: [String: JSONValue]) -> JSONValue {
            .object(["type": .string("object"), "properties": .object(props),
                     "required": .array(props.keys.sorted().map { .string($0) }), "additionalProperties": .bool(false)])
        }
        return obj([
            "title": str(),
            "classification": .object(["type": .string("string"), "enum": .array([.string("allowed"), .string("allowed_with_gates"), .string("refused")])]),
            "refusal_reason": str(),
            "objects": arr(obj(["id": str(), "name": str(), "phrase": str(), "text": arr(str())])),
            "steps": arr(obj([
                "instruction": str(), "why": str(), "targets": arr(str()),
                "check_kind": .object(["type": .string("string"), "enum": .array([.string("camera"), .string("user"), .string("none")])]),
                "expected": str(), "cautions": arr(str()), "gate": str(), "source_ref": str(),
            ])),
            "cautions": arr(str()),
            "mismatch": str(),
        ])
    }()

    /// The first complete {...} in a model's text (it may add words around the JSON).
    static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...i]) }
            }
            i = text.index(after: i)
        }
        return nil
    }
}

public enum CompilerError: Error, CustomStringConvertible {
    case unreadable(String)
    case invalid([String])

    public var description: String {
        switch self {
        case .unreadable(let t): return "the plan could not be read: \(t)"
        case .invalid(let p): return "the plan is incomplete: \(p.joined(separator: "; "))"
        }
    }
}
