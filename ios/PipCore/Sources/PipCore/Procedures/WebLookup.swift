import Foundation

/// Looks a fact up on the web when the guide is not sure of it (a setting, what a light or an
/// error code means, a replacement part), so Pip answers from a source instead of guessing.
///
/// Spark with Meta's web search: on 1 Nov it answered three appliance questions from the
/// manufacturers' own manuals and support pages in 7–12 s. Wonder took 26 s and 140k tokens for one.
public struct WebLookup: Sendable {
    public var client: PipClient
    public var language: String
    public var model = "muse-spark-1.3"
    /// A spoken assistant cannot keep the user waiting longer than this.
    public var timeout: TimeInterval = 45

    public init(client: PipClient, language: String) {
        self.client = client
        self.language = language
    }

    public struct Source: Codable, Equatable, Sendable {
        public var title: String
        public var url: String
        public var publisher: String
        /// Published by the product's manufacturer (or the company that now makes the brand's products).
        public var official: Bool

        public init(title: String, url: String, publisher: String, official: Bool) {
            self.title = title
            self.url = url
            self.publisher = publisher
            self.official = official
        }

        public var host: String { URL(string: url)?.host?.lowercased().replacingOccurrences(of: "www.", with: "") ?? "" }
        public var isPDF: Bool { url.lowercased().contains(".pdf") }
    }

    public struct Answer: Equatable, Sendable {
        public var found: Bool
        /// Short sentences in the conversation language, as the source gives the facts.
        public var answer: String
        public var sources: [Source]
        /// Pages the search tool really opened or cited: a source among them is known to exist.
        public var cited: [String]
        public var seconds: Double

        public init(found: Bool, answer: String, sources: [Source], cited: [String], seconds: Double = 0) {
            self.found = found
            self.answer = answer
            self.sources = sources
            self.cited = cited
            self.seconds = seconds
        }

        /// A source the search tool really opened, the manufacturer's first; mirror sites only if
        /// nothing else was found. nil when no source checks out.
        public var best: Source? {
            let real = sources.filter { s in cited.contains { Self.samePage($0, s.url) } }
            let ranked = real.filter { !ProcedureCompiler.unofficial($0.host) }
            return ranked.first(where: \.official) ?? ranked.first ?? real.first
        }

        /// Whether to say where it comes from as an official source.
        public var official: Bool { best.map { $0.official && !ProcedureCompiler.unofficial($0.host) } ?? false }

        static func samePage(_ a: String, _ b: String) -> Bool {
            func norm(_ s: String) -> String {
                var t = s.lowercased()
                for p in ["https://", "http://", "www."] where t.hasPrefix(p) { t.removeFirst(p.count) }
                if let i = t.firstIndex(where: { $0 == "#" || $0 == "?" }) { t = String(t[..<i]) }
                while t.hasSuffix("/") { t.removeLast() }
                return t
            }
            return norm(a) == norm(b)
        }
    }

    /// `question`: what to find out, as the guide wrote it (with brand and model). `asked`: the
    /// user's own words. `facts`: what Pip knows (the device, its model, the task).
    public func answer(_ question: String, asked: String, facts: [String]) async throws -> Answer {
        let t0 = Date()
        let body: JSONValue = .object([
            "model": .string(model),
            "input": .array([.object(["role": .string("user"), "content": .array([
                .object(["type": .string("input_text"), "text": .string(instructions(question, asked: asked, facts: facts))]),
            ])])]),
            "tools": .array([.object(["type": .string("web_search")])]),
            "reasoning": .object(["effort": .string("low")]),
            "text": .object(["format": .object([
                "type": .string("json_schema"), "name": .string("lookup"), "strict": .bool(true), "schema": Self.schema,
            ])]),
            // Spark used 0.9–1.5k output tokens (reasoning included); Wonder ran out at 2k.
            "max_output_tokens": .number(4000),
        ])
        let output = try await client.responses(body, timeout: timeout)
        var answer = try Self.read(output)
        answer.seconds = Date().timeIntervalSince(t0)
        return answer
    }

    func instructions(_ question: String, asked: String, facts: [String]) -> String {
        var lines = [
            "You look things up for Pip, a voice assistant that guides a hands-on task through the user's phone camera. Pip must not guess: answer only from what you find.",
            "Question to answer: \(question)",
            "The user asked Pip: \"\(asked)\"",
        ]
        if !facts.isEmpty { lines.append("What Pip knows: " + facts.joined(separator: "; ")) }
        lines += [
            "Search the web. Use the manufacturer's own pages first (manual, support, FAQ), then other reliable sources. Do not rely on forums or unofficial manual-collection sites unless nothing else exists, and say so.",
            "Answer in \(language), in at most three short sentences a person can say aloud: the exact values, names, symbols and steps as the source gives them, for this product if it is named.",
            "If you find nothing reliable, or the sources disagree, set found to false and say briefly what is unclear.",
            "List the pages you used in sources: title, url, publisher, and official = true when the product's manufacturer published it.",
        ]
        return lines.joined(separator: "\n")
    }

    /// The answer is the last message that holds the JSON (the ones before narrate the search).
    static func read(_ output: PipClient.ResponsesOutput) throws -> Answer {
        struct Raw: Decodable { var found: Bool; var answer: String; var sources: [Source] }
        for text in output.texts.reversed() {
            guard let json = ProcedureCompiler.firstJSONObject(in: text), let raw = try? JSONDecoder().decode(Raw.self, from: Data(json.utf8)) else { continue }
            let answer = raw.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return Answer(found: raw.found && !answer.isEmpty, answer: answer, sources: raw.sources, cited: output.citations)
        }
        throw LookupError.unreadable(String(output.texts.last?.prefix(200) ?? ""))
    }

    public enum LookupError: Error { case unreadable(String) }

    static let schema: JSONValue = {
        func str() -> JSONValue { .object(["type": .string("string")]) }
        let source: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["title": str(), "url": str(), "publisher": str(), "official": .object(["type": .string("boolean")])]),
            "required": .array(["title", "url", "publisher", "official"].map { .string($0) }),
            "additionalProperties": .bool(false),
        ])
        return .object([
            "type": .string("object"),
            "properties": .object([
                "found": .object(["type": .string("boolean")]),
                "answer": str(),
                "sources": .object(["type": .string("array"), "items": source]),
            ]),
            "required": .array(["found", "answer", "sources"].map { .string($0) }),
            "additionalProperties": .bool(false),
        ])
    }()
}
