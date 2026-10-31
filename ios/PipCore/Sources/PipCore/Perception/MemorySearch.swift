import CoreGraphics
import CoreText
import Foundation

/// Searches Pip's visual memory: snapshots go to Muse Wonder as numbered contact sheets (16 per
/// image, newest first), and Wonder says in which snapshots the object appears and where. The
/// caller confirms each sighting with SAM before pointing: nothing is pointed at on a guess.
public struct MemorySearch: Sendable {
    public var client: PipClient
    public var model = "muse-wonder-1.0"
    public static let tilesPerSheet = 16
    public static let maxSheets = 12

    public init(client: PipClient) {
        self.client = client
    }

    public struct Sighting: Equatable, Sendable {
        /// Index into the snapshots passed in.
        public var index: Int
        /// Position in that snapshot, 0–1000 on both axes.
        public var x: Double
        public var y: Double
        public var confidence: Double
    }

    /// `snapshots` are JPEGs, oldest first. Returns the most recent sightings first.
    public func find(_ what: String, in snapshots: [Data]) async throws -> [Sighting] {
        let recent = Array(snapshots.suffix(Self.tilesPerSheet * Self.maxSheets))
        let offset = snapshots.count - recent.count
        guard !recent.isEmpty else { return [] }
        var sheets: [Data] = []
        for start in stride(from: 0, to: recent.count, by: Self.tilesPerSheet) {
            let tiles = Array(recent[start..<min(start + Self.tilesPerSheet, recent.count)])
            if let sheet = Self.sheet(tiles, firstNumber: start + 1) { sheets.append(sheet) }
        }
        let question = """
        These are numbered snapshots from the user's phone camera, \(recent.count) in total; a higher number is more recent. \
        Find: "\(what)". Look at every tile carefully. List where it appears, the most recent sightings first (at most 3): \
        tile is the number on the tile, and x, y the centre of the object within that tile on a 0–1000 grid (x from the left, y from the top). \
        Only list tiles where you clearly see it; if you do not see it anywhere, found is false.
        """
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "found": .object(["type": .string("boolean")]),
                "sightings": .object(["type": .string("array"), "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "tile": .object(["type": .string("integer")]),
                        "x": .object(["type": .string("number")]),
                        "y": .object(["type": .string("number")]),
                        "confidence": .object(["type": .string("number")]),
                    ]),
                    "required": .array([.string("tile"), .string("x"), .string("y"), .string("confidence")]),
                    "additionalProperties": .bool(false),
                ])]),
            ]),
            "required": .array([.string("found"), .string("sightings")]),
            "additionalProperties": .bool(false),
        ])
        var request = ChatRequest(messages: [ChatMessage(role: .user, parts: [.text(question)] + sheets.map { .imageJPEG($0) })], stream: false,
                                  reasoningEffort: .minimal, responseFormat: ResponseFormat(name: "memory_search", schema: schema))
        request.model = model
        let (text, _) = try await client.chat(request)
        struct Out: Decodable {
            struct S: Decodable { var tile: Int; var x: Double; var y: Double; var confidence: Double }
            var found: Bool
            var sightings: [S]
        }
        let out = try JSONDecoder().decode(Out.self, from: Data(text.utf8))
        guard out.found else { return [] }
        return out.sightings
            .filter { (1...recent.count).contains($0.tile) && (0...1000).contains($0.x) && (0...1000).contains($0.y) }
            .map { Sighting(index: offset + $0.tile - 1, x: $0.x, y: $0.y, confidence: $0.confidence) }
            .sorted { $0.index > $1.index }
    }

    /// A 4×4 contact sheet of portrait tiles (192×256), each with its number in a corner.
    static func sheet(_ tiles: [Data], firstNumber: Int) -> Data? {
        let tw = 192, th = 256, cols = 4
        let rows = Int(ceil(Double(tiles.count) / Double(cols)))
        guard rows > 0, let ctx = CGContext(data: nil, width: tw * cols, height: th * rows, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: tw * cols, height: th * rows))
        for (i, data) in tiles.enumerated() {
            guard let image = SetOfMarks.load(data, maxSide: th) else { continue }
            let col = i % cols, row = i / cols
            // CoreGraphics' origin is bottom-left: the first row goes at the top.
            let rect = CGRect(x: col * tw, y: (rows - 1 - row) * th, width: tw, height: th)
            ctx.draw(image, in: rect.insetBy(dx: 1, dy: 1))
            let label = "\(firstNumber + i)"
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 18, nil)
            let attributed = CFAttributedStringCreate(nil, label as CFString, [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 0.2, alpha: 1)] as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attributed)
            let w = CTLineGetTypographicBounds(line, nil, nil, nil)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.8))
            ctx.fill(CGRect(x: rect.minX + 2, y: rect.maxY - 26, width: CGFloat(w) + 10, height: 24))
            ctx.textPosition = CGPoint(x: rect.minX + 7, y: rect.maxY - 20)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage().flatMap { SetOfMarks.jpeg($0, quality: 0.75) }
    }
}

/// Shopping-list mode: which list items are in the basket now, and which product looks like a
/// list item but is a different variant. The caller ticks an item off after two sightings in a row.
public struct BasketChecker: Sendable {
    public var client: PipClient
    public var model = "muse-spark-1.3"

    public init(client: PipClient) {
        self.client = client
    }

    public struct Result: Equatable, Sendable {
        public var inBasket: [String]
        public var wrong: [(item: String, seen: String)]

        public static func == (a: Result, b: Result) -> Bool { a.inBasket == b.inBasket && a.wrong.map(\.item) == b.wrong.map(\.item) }
    }

    public func check(_ frame: CGImage, needed: [String]) async throws -> Result {
        guard let jpeg = SetOfMarks.resize(frame, maxSide: 896).flatMap({ SetOfMarks.jpeg($0, quality: 0.75) }) else { return Result(inBasket: [], wrong: []) }
        let question = """
        Someone is shopping with this list of items still to get: \(needed.map { "\"\($0)\"" }.joined(separator: ", ")).
        1. in_basket: which of these exact items are clearly visible inside the shopping basket or trolley in this image (use the list's wording)? Products on the shelf do not count.
        2. wrong: a product inside the basket that looks like a list item but is clearly a different variant (full-fat instead of semi-skimmed, a different brand or size when the list names one). Give the list item and what you see.
        Only report what you clearly see.
        """
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "in_basket": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                "wrong": .object(["type": .string("array"), "items": .object([
                    "type": .string("object"),
                    "properties": .object(["item": .object(["type": .string("string")]), "seen": .object(["type": .string("string")])]),
                    "required": .array([.string("item"), .string("seen")]),
                    "additionalProperties": .bool(false),
                ])]),
            ]),
            "required": .array([.string("in_basket"), .string("wrong")]),
            "additionalProperties": .bool(false),
        ])
        var request = ChatRequest(messages: [ChatMessage(role: .user, parts: [.text(question), .imageJPEG(jpeg)])], stream: false,
                                  reasoningEffort: .minimal, responseFormat: ResponseFormat(name: "basket", schema: schema))
        request.model = model
        let (text, _) = try await client.chat(request)
        struct Out: Decodable {
            struct W: Decodable { var item: String; var seen: String }
            var in_basket: [String]
            var wrong: [W]
        }
        let out = try JSONDecoder().decode(Out.self, from: Data(text.utf8))
        let lower = Set(needed.map { $0.lowercased() })
        return Result(inBasket: out.in_basket.filter { lower.contains($0.lowercased()) },
                      wrong: out.wrong.filter { lower.contains($0.item.lowercased()) }.map { ($0.item, $0.seen) })
    }
}
