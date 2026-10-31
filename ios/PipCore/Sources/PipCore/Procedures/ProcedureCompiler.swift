import Foundation

/// An official document for a product, found on the web and checked to exist.
public struct ManualReference: Codable, Equatable, Sendable {
    public var title: String
    public var publisher: String
    public var url: String
    /// A web page of the manufacturer's (a support page) rather than a PDF; nil for a PDF.
    public var page: Bool?

    public init(title: String, publisher: String, url: String, page: Bool? = nil) {
        self.title = title
        self.publisher = publisher
        self.url = url
        self.page = page
    }

    public var isPage: Bool { page == true }
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

    static func unofficial(_ host: String) -> Bool { unofficialHosts.contains { host.contains($0) } }

    public func findManual(for product: String) async throws -> ManualReference? {
        try await findSource(for: product).manual
    }

    /// The manufacturer's PDF manual for `product` or, when there is none to be had, its official
    /// support page; with a note on what was found or why nothing was taken (for the log). The
    /// manufacturer may be a company that makes the brand's products now (Versuni for Philips
    /// household appliances): the model judges that, mirror sites are refused here.
    public func findSource(for product: String) async throws -> (manual: ManualReference?, note: String) {
        let prompt = """
        Find the official assembly instructions, installation guide or user manual for: \(product).
        Use only the manufacturer's own website (or the company that now makes the brand's products), never mirror or manual-collection sites.
        I need the direct link to the PDF file. If there is no PDF, give the official support page for the product instead.
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
        guard let json = Self.firstJSONObject(in: text), let found = try? JSONDecoder().decode(Found.self, from: Data(json.utf8)) else {
            return (nil, "no answer to read")
        }
        guard found.found == true else { return (nil, "the search found no official document") }
        var notes: [String] = []
        // Models can produce a link that looks right but does not exist, or that redirects to a
        // web page or a mirror site: only a real PDF, or else a real page, on an official site counts.
        for (link, wantPDF) in [(found.pdf_url, true), (found.page_url, false)] {
            guard let url = link, !url.isEmpty else { continue }
            guard let host = URL(string: url)?.host?.lowercased(), !Self.unofficial(host) else {
                notes.append("\(url) is not the manufacturer's")
                continue
            }
            let check = try await client.sourceCheck(url)
            let finalHost = (check.host ?? host).lowercased()
            guard check.ok, (check.pdf == true) == wantPDF, !Self.unofficial(finalHost) else {
                notes.append("\(url) did not check out (\(check.ok ? (check.pdf == true ? "a PDF" : "not a PDF") : "unreachable"))")
                continue
            }
            let manual = ManualReference(title: found.title ?? product, publisher: found.publisher ?? host, url: check.finalUrl ?? url, page: wantPDF ? nil : true)
            return (manual, (wantPDF ? "PDF " : "support page ") + manual.url)
        }
        return (nil, notes.isEmpty ? "no link given" : notes.joined(separator: "; "))
    }

    // MARK: Compiling

    public func compile(goal: String, source: SourceInput, frameJPEG: Data?, facts: [String]) async throws -> Compiled {
        let t0 = Date()
        var content: [JSONValue] = [.object(["type": .string("input_text"), "text": .string(instructions(goal: goal, source: source, facts: facts))])]
        switch source {
        case .manual(let m) where !m.isPage:
            content.append(.object(["type": .string("input_file"), "file_url": .string(m.url)]))
        case .manual:
            break
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
        var fields: [String: JSONValue] = [
            "model": .string(compilerModel),
            "input": .array([.object(["role": .string("user"), "content": .array(content)])]),
            "reasoning": .object(["effort": .string("low")]),
            "text": .object(["format": .object([
                "type": .string("json_schema"), "name": .string("procedure"), "strict": .bool(true), "schema": Self.schema,
            ])]),
        ]
        // A support page is read with the web tool; without any source the model may search.
        if Self.searches(source) { fields["tools"] = .array([.object(["type": .string("web_search")])]) }
        let body: JSONValue = .object(fields)
        let text = try await client.responsesText(body)
        guard let json = Self.firstJSONObject(in: text) else { throw CompilerError.unreadable(String(text.prefix(200))) }
        let raw = try JSONDecoder().decode(RawProcedure.self, from: Data(json.utf8))
        return try raw.compiled(goal: goal, source: source, seconds: Date().timeIntervalSince(t0), language: language)
    }

    func instructions(goal: String, source: SourceInput, facts: [String]) -> String {
        let sourceLine: String
        switch source {
        case .manual(let m) where m.isPage: sourceLine = "The official support page from \(m.publisher) is \(m.url) (\(m.title)). Open it, and the manual it links to if there is one, and base every step on it; source_ref names the section. List the pages you used in sources."
        case .manual(let m): sourceLine = "The attached PDF is the official document from \(m.publisher): \(m.title). Base every step on it and give its page number as source_ref."
        case .images: sourceLine = "The attached photos are the user's instructions. Base every step on them and give the photo number as source_ref (\"photo 1\")."
        case .text: sourceLine = "The SOURCE TEXT is the user's instructions. Base every step on it; source_ref quotes a few words of it."
        case .none: sourceLine = "There is no verified source. Search the web for the manufacturer's instructions for this task and product (or a reliable guide), and base the steps on what you find, with the page in source_ref and every page you used in sources. If nothing useful turns up, draft conservatively from general knowledge with source_ref and sources empty. It will be marked as not from a verified source."
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
        /// Pages the model used (support page, web search results).
        var sources: [String]?

        func compiled(goal: String, source: SourceInput, seconds: Double, language: String = "English") throws -> Compiled {
            let src: Procedure.Source
            switch source {
            case .manual(let m) where m.isPage: src = .init(kind: .page, reference: "\(m.publisher): \(m.title) (\(m.url))")
            case .manual(let m): src = .init(kind: .pdf, reference: "\(m.publisher): \(m.title) (\(m.url))")
            case .images(let p): src = .init(kind: .images, reference: "\(p.count) photo(s) of the instructions")
            case .text: src = .init(kind: .text, reference: "the user's text")
            case .none:
                // Found on the web: shown with its pages, but never as verified.
                let pages = (sources ?? []).filter { $0.hasPrefix("http") }
                src = pages.isEmpty ? .init(kind: .none) : .init(kind: .web, reference: pages.prefix(3).joined(separator: ", "))
            }
            var procedure = Procedure(
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
            case "refused": modelClass = .refused(reason: SafetyPolicy.refusalReasons.contains(refusal_reason) ? refusal_reason : "other")
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
                // Gated work always has a safety question before it starts, also when the model gave none.
                if final == .allowedWithGates, !procedure.steps.contains(where: { $0.gate != nil }), !procedure.steps.isEmpty {
                    procedure.steps[0].gate = language.lowercased() == "dutch"
                        ? "je handen zijn droog, er is niets nat in de buurt en je ziet geen schade of brandsporen"
                        : "your hands are dry, nothing near it is wet, and you see no damage or burn marks"
                }
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
            "refusal_reason": .object(["type": .string("string"), "enum": .array(([""] + SafetyPolicy.refusalReasons).map { .string($0) })]),
            "objects": arr(obj(["id": str(), "name": str(), "phrase": str(), "text": arr(str())])),
            "steps": arr(obj([
                "instruction": str(), "why": str(), "targets": arr(str()),
                "check_kind": .object(["type": .string("string"), "enum": .array([.string("camera"), .string("user"), .string("none")])]),
                "expected": str(), "cautions": arr(str()), "gate": str(), "source_ref": str(),
            ])),
            "cautions": arr(str()),
            "mismatch": str(),
            "sources": arr(str()),
        ])
    }()

    /// Whether the compiler may use the web tool for this source.
    static func searches(_ source: SourceInput) -> Bool {
        switch source {
        case .manual(let m): return m.isPage
        case .none: return true
        case .images, .text: return false
        }
    }

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
