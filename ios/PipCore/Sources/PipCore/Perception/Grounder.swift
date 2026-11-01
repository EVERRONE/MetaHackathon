import CoreGraphics
import Foundation
import Vision

/// What the model asked to point at: a rough position, a detector word and the text printed on it.
public struct TargetSpec: Equatable, Sendable {
    /// Centre on a 0–1000 grid of the frame.
    public var x: Double
    public var y: Double
    /// Detector noun for SAM: "key", "breaker", "knob".
    public var phrase: String
    /// Text printed on the object, alternatives allowed ("0", "à", "@").
    public var text: [String]
    /// The object a small target is part of ("remote control" for a key on it): Pip locks the
    /// outline to that object in 3D, so it stays on the key when the remote moves.
    public var on: String?
    /// A small target (a ring: a key, a button, an LED), not a whole object.
    public var small = false

    public init(x: Double, y: Double, phrase: String, text: [String] = [], on: String? = nil, small: Bool = false) {
        self.x = x
        self.y = y
        self.phrase = phrase
        self.text = text
        self.on = on
        self.small = small
    }

    public func point(in size: CGSize) -> CGPoint {
        CGPoint(x: x / 1000 * size.width, y: y / 1000 * size.height)
    }
}

public struct GroundingResult: Sendable {
    public var instance: SegmentInstance?
    /// How the instance was chosen, for the trace.
    public var method: String
    public var seconds: Double
}

/// Turns a rough target into an exact SAM outline, checked against the text printed on it.
///
/// SAM segments the kind of object in the region around the point while on-device text
/// recognition looks for the printed text. The instance under the recognised text wins; then the
/// instance under the point; then SAM's own point-prompted mask; then the nearest instance.
public struct Grounder: Sendable {
    public var client: PipClient
    /// Whole-frame SAM results per phrase, shared by all targets of one look.
    let wholeFrame: WholeFrameSegments

    /// `frameJPEG` is the whole frame, encoded once per look: large objects are found better whole,
    /// small ones on the enlarged crop, so SAM looks at both.
    public init(client: PipClient, frameJPEG: Data) {
        self.client = client
        self.wholeFrame = WholeFrameSegments(client: client, jpeg: frameJPEG)
    }

    /// `describe`: what the model said the object is ("the power symbol"), once its words are in;
    /// used to check objects without printed text.
    public func ground(_ spec: TargetSpec, id: Int, frame: CGImage, describe: (@Sendable () -> String?)? = nil) async -> GroundingResult {
        let t0 = Date()
        let size = CGSize(width: frame.width, height: frame.height)
        let p = spec.point(in: size)
        let side = max(size.width, size.height) * 0.32
        let region = CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)
            .intersection(CGRect(origin: .zero, size: size)).integral
        let scale = min(2.5, 1024 / max(region.width, region.height))
        guard let crop = SetOfMarks.crop(frame, to: region, scale: scale), let jpeg = SetOfMarks.jpeg(crop, quality: 0.85) else {
            return GroundingResult(instance: nil, method: "crop failed", seconds: 0)
        }
        let local = CGPoint(x: (p.x - region.minX) * scale, y: (p.y - region.minY) * scale)
        let object = SegmentObjectPrompt(id: 1, points: [.init(x: min(max(Int(local.x), 0), crop.width - 1), y: min(max(Int(local.y), 0), crop.height - 1))])
        // The model's point can be a little off its object (on its edge, or in the gap beside it):
        // SAM also segments at six points round it, in the same request, so the object itself is
        // among the masks when the point's own mask is not (1 Nov: a sliver beside a statue).
        let ringRadius = Double(max(crop.width, crop.height)) * (spec.small ? 0.02 : 0.035)
        var objects = [object]
        for k in 0..<6 {
            let a = Double(k) / 6 * 2 * .pi
            let x = Int(Double(local.x) + ringRadius * cos(a)), y = Int(Double(local.y) + ringRadius * sin(a))
            guard x >= 0, y >= 0, x < crop.width, y < crop.height else { continue }
            objects.append(SegmentObjectPrompt(id: 2 + k, points: [.init(x: x, y: y)]))
        }

        // A small target may be a printed symbol (a power icon on a panel) rather than a part of
        // its own: SAM also looks for icons around it.
        // Only for targets without printed text: on keys, SAM would find the printed letters.
        let iconLike = spec.small && spec.text.isEmpty
        let prompts = iconLike && spec.phrase != "icon" ? [spec.phrase, "icon"] : [spec.phrase]
        let allObjects = objects
        async let segmented = Result { try await client.segment(SegmentRequest(jpeg: jpeg, prompts: prompts, objects: allObjects, width: crop.width, height: crop.height, minConfidence: 0.25, maxInstances: 120)) }
        async let whole = wholeFrame.instances(for: spec.phrase)
        let debug = ProcessInfo.processInfo.environment["PIP_DEBUG_GROUND"] != nil
        // Text recognition runs alongside SAM: the fast pass always (≈0.05 s), the accurate pass
        // within a budget, because after a pause it reloads its models (~25 s).
        // Vision handles requests one at a time, so even the fast pass can queue behind another
        // target's cold accurate pass: both get a budget.
        async let fastText = Self.withBudget(Self.fastTextBudget) { await Self.findText(spec.text, in: crop, accurate: false) }
        async let accurateText = Self.withBudget(Self.accurateTextBudget) { await Self.findText(spec.text, in: crop, accurate: true) }
        let (fast, accurate) = await (fastText, accurateText)
        let found = (accurate?.isEmpty == false ? accurate : nil) ?? fast ?? []
        if debug { print(String(format: "[ground %d] text done %.2f (%d found)", id, Date().timeIntervalSince(t0), found.count)) }
        let wholeInstances = await whole
        let seg = await segmented
        if debug { print(String(format: "[ground %d] SAM done %.2f", id, Date().timeIntervalSince(t0))) }
        var problems: [String] = []
        if case .failure(let e) = seg { problems.append("crop SAM failed: \(e)") }
        if wholeInstances == nil { problems.append("whole-frame SAM failed") }

        let instances = (try? seg.get())?.instances ?? []
        // Whole-frame instances in crop coordinates, kept when they reach into the crop and are not
        // already found on the crop. Both requests number their instances from 1, so the
        // whole-frame ones get ids from 10 000 to keep them apart.
        let cropBounds = CGRect(x: 0, y: 0, width: crop.width, height: crop.height)
        var concept = instances.filter { $0.objectId == nil }
        for inst in (wholeInstances ?? []).map({ $0.mapped(into: region, scale: scale).renumbered($0.id + 10_000) }) where inst.boxRect.intersects(cropBounds) {
            if !concept.contains(where: { iou($0.boxRect, inst.boxRect) > 0.6 }) { concept.append(inst) }
        }
        let cropArea = Double(crop.width * crop.height)
        var chosen: SegmentInstance?
        var method = "none"
        if ProcessInfo.processInfo.environment["PIP_DEBUG_OCR"] != nil {
            print("crop \(crop.width)x\(crop.height) local \(Int(local.x)),\(Int(local.y)) concept \(concept.count):", concept.map { "\($0.box) \(String(format: "%.2f", $0.confidence))" }.joined(separator: " "), "prompted:", instances.filter { $0.objectId != nil }.map { "\($0.box)" })
        }

        // 1. Printed text near the model's point, nearest first. Spark's points can be off by about one
        //    object, never by many, so text further away (the "0" in "F10") is not this object.
        let sizes = concept.map { sqrt(Double($0.area)) }.sorted()
        let typical = sizes.isEmpty ? 80 : sizes[sizes.count / 2]
        let reach = max(1.6 * typical, 60)
        // Words ("alt gr", "10F") are distinctive anywhere in the region; single characters only close by.
        let nearby = found.filter { $0.length >= 2 || hypot(Double($0.rect.midX - local.x), Double($0.rect.midY - local.y)) <= reach }
        for match in nearby.sorted(by: { hypot($0.rect.midX - local.x, $0.rect.midY - local.y) < hypot($1.rect.midX - local.x, $1.rect.midY - local.y) }) {
            let c = CGPoint(x: match.rect.midX, y: match.rect.midY)
            if let hit = concept.filter({ Grounding.contains($0, c) && Double($0.area) < cropArea * 0.4 }).min(by: { $0.area < $1.area }) {
                chosen = hit
                method = "text"
                break
            }
        }
        // 2. The instance under the point.
        if chosen == nil, let hit = concept.filter({ Grounding.contains($0, local) && Double($0.area) < cropArea * 0.4 }).min(by: { $0.area < $1.area }) {
            chosen = hit
            method = "point"
        }
        // 3. SAM's mask for the point itself, unless it is only a small part (a label on a breaker).
        if chosen == nil, let prompted = instances.first(where: { $0.objectId == 1 }), Double(prompted.area) < cropArea * 0.3,
           concept.isEmpty || Double(prompted.area) >= 0.3 * typical * typical {
            chosen = prompted
            method = "point prompt"
        }
        // 4. The nearest instance, if close.
        if chosen == nil, let near = concept.min(by: { Grounding.distance(local, $0.boxRect) < Grounding.distance(local, $1.boxRect) }),
           Grounding.distance(local, near.boxRect) < 0.6 * sqrt(Double(near.area)) {
            chosen = near
            method = "nearest"
        }

        // Look-alikes around a point the text could not confirm (small keys, rows of breakers), or
        // an object without printed text that the model described ("the power symbol"): ask Spark
        // to pick between them on an enlarged crop, by the printed text or the description.
        let description = spec.text.isEmpty ? describe?() : nil
        if let current = chosen, method != "text", !spec.text.isEmpty || description != nil {
            // An outsized pick (the space bar for a key) is compared with objects of the usual size.
            let reference = min(Double(current.area), 2.5 * typical * typical)
            var lookalikes = concept
                .filter { $0.id != current.id && Double($0.area) > 0.4 * reference && Double($0.area) < 2.5 * reference }
                .filter { Grounding.distance(local, $0.boxRect) <= 2.2 * reach }
                .sorted { Grounding.distance(local, $0.boxRect) < Grounding.distance(local, $1.boxRect) }
            // A small target may hide inside a bigger pick (the power symbol on a shaver's panel):
            // smaller things under or next to the point are candidates too, and SAM's own mask
            // for the point.
            if iconLike {
                let inner = (concept + instances.filter { $0.objectId == 1 })
                    .filter { $0.id != current.id && Double($0.area) < 0.6 * Double(current.area) && Double($0.area) > 0.02 * Double(current.area) }
                    .filter { Grounding.distance(local, $0.boxRect) <= reach }
                    .filter { inner in !lookalikes.contains { $0.id == inner.id } }
                lookalikes += inner.prefix(4)
            }
            // The point's own mask is not a solid object (a sliver, unsure): the most solid mask of the
            // points round it, nearest to the model's point, is the object. Geometry only, no model
            // call: asking the verifier here doubled the wait (5.4 s on 1 Nov).
            let doubtful = method == "point prompt" && !Self.solid(current)
            if doubtful {
                let round = instances.filter { ($0.objectId ?? 0) >= 2 && Double($0.area) < cropArea * 0.4 && Double($0.area) > cropArea * 0.0004 }
                if let best = round.filter({ Self.solid($0) }).min(by: { a, b in
                    let da = Grounding.distance(local, a.boxRect), db = Grounding.distance(local, b.boxRect)
                    return da != db ? da < db : a.confidence > b.confidence
                }), Grounding.distance(local, best.boxRect) <= 1.5 * ringRadius {
                    chosen = best
                    method = "point ring"
                }
            }
            // Verification chooses between look-alikes. One object under the model's own point
            // needs none: asked about it alone, the verifier (without the conversation) sometimes
            // said no to the right object and only cost a second or two (1 Nov: both statues, which
            // SAM found only at the model's point, were refused; the speech waited for it).
            // The model's point deep inside one of them (a quarter of its size from every edge):
            // that is the one it means, and the speech need not wait for a check. Points near an
            // edge or in a gap are checked.
            if let current = chosen, method == "point", Self.deepInside(local, current.boxRect) { lookalikes = [] }
            if !lookalikes.isEmpty, let current = chosen {
                switch await verify(spec, description: description, point: local, candidates: [current] + lookalikes.filter { $0.id != current.id }.prefix(10), in: crop) {
                case .picked(let picked):
                    method = picked.id == current.id ? "verified" : "verified (moved)"
                    chosen = picked
                case .noneOfThem where spec.text.isEmpty && !spec.small:
                    // A whole object without printed text to check: the model's own point decides.
                    method += " (verifier unsure; the model's point)"
                case .noneOfThem:
                    // A key or button that does not show the printed text: never point at a guess.
                    method = "rejected by verification"
                    chosen = nil
                case .failed:
                    method += " (unverified)"
                }
            }
        }

        var result = chosen?.unmapped(from: region, scale: scale).renumbered(id)
        if method == "text", result != nil { result!.confidence = max(result!.confidence, 0.85) }
        if result != nil { result!.objectId = nil }
        if nearby.isEmpty && !spec.text.isEmpty { problems.append("text not found nearby") }
        return GroundingResult(instance: result, method: method + (problems.isEmpty ? "" : " (\(problems.joined(separator: "; ")))"), seconds: Date().timeIntervalSince(t0))
    }

    static func deepInside(_ p: CGPoint, _ box: CGRect) -> Bool {
        guard box.width > 0, box.height > 0, box.contains(p) else { return false }
        let fx = min(p.x - box.minX, box.maxX - p.x) / box.width
        let fy = min(p.y - box.minY, box.maxY - p.y) / box.height
        return fx >= 0.25 && fy >= 0.25
    }

    /// A mask that looks like a whole object: SAM is sure of it, and it is not a sliver.
    public static func solid(_ i: SegmentInstance) -> Bool {
        let b = i.boxRect
        let fill = Double(i.area) / max(1, Double(b.width * b.height))
        let aspect = Double(min(b.width, b.height) / max(b.width, b.height, 1))
        return i.confidence >= 0.8 && fill >= 0.35 && aspect >= 0.3
    }

    static let fastTextBudget: TimeInterval = 0.8
    static let accurateTextBudget: TimeInterval = 1.5

    /// Re-measures an object around where it was last seen (a box in frame pixels): SAM segments
    /// the object under that box on an enlarged crop. Used to follow objects that moved and to
    /// snap outlines back after the user returns.
    public func reground(box: CGRect, id: Int, frame: CGImage) async -> SegmentInstance? {
        let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let pad = max(box.width, box.height) * 0.6 + 24
        let region = box.insetBy(dx: -pad, dy: -pad).intersection(bounds).integral
        // The box itself in the frame (a box just outside it has no pixels to prompt with).
        let inFrame = box.intersection(bounds)
        guard !region.isNull, !inFrame.isNull, region.width > 16, region.height > 16, inFrame.width >= 1, inFrame.height >= 1 else { return nil }
        let scale = min(2.5, 1024 / max(region.width, region.height))
        guard let crop = SetOfMarks.crop(frame, to: region, scale: scale), let jpeg = SetOfMarks.jpeg(crop, quality: 0.85) else { return nil }
        let local = inFrame.offsetBy(dx: -region.minX, dy: -region.minY)
        let scaled = [Int(local.minX * scale), Int(local.minY * scale), Int(local.maxX * scale), Int(local.maxY * scale)]
        let prompt = SegmentObjectPrompt(id: 1, box: scaled)
        guard let seg = try? await client.segment(SegmentRequest(jpeg: jpeg, objects: [prompt], width: crop.width, height: crop.height, minConfidence: 0.3)),
              let inst = seg.instances.first(where: { $0.objectId == 1 }) else { return nil }
        var out = inst.unmapped(from: region, scale: scale).renumbered(id)
        out.objectId = nil
        return out
    }

    /// The object named `phrase` ("keys", "cup") at a point of an image (an earlier snapshot):
    /// SAM looks for that kind of object in the region around the point, and the instance under
    /// the point (or nearest, within about a hand's width in the image) is it. nil when SAM finds
    /// no such object there: then it was a different thing, and Pip does not point.
    public func object(named phrase: String, at point: CGPoint, in image: CGImage, id: Int) async -> SegmentInstance? {
        guard !phrase.isEmpty else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        // Close up first (small things like keys), then the whole image (a laptop, a chair).
        for fraction in [0.4, 1.0] {
            let side = max(size.width, size.height) * fraction
            let region = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side).intersection(CGRect(origin: .zero, size: size)).integral
            guard !region.isNull, region.width > 16, region.height > 16 else { continue }
            let scale = min(2.0, 1024 / max(region.width, region.height))
            guard let crop = SetOfMarks.crop(image, to: region, scale: scale), let jpeg = SetOfMarks.jpeg(crop, quality: 0.85),
                  let seg = try? await client.segment(SegmentRequest(jpeg: jpeg, prompts: [phrase], width: crop.width, height: crop.height, minConfidence: 0.3, maxInstances: 40))
            else { continue }
            let local = CGPoint(x: (point.x - region.minX) * scale, y: (point.y - region.minY) * scale)
            let reach = 0.08 * Double(max(crop.width, crop.height))
            let maxArea = (fraction < 1 ? 0.5 : 0.8) * Double(crop.width * crop.height)
            let candidates = seg.instances.filter { Double($0.area) < maxArea }
            let hit = candidates.filter { Grounding.contains($0, local) }.min { $0.area < $1.area }
                ?? candidates.filter { Grounding.distance(local, $0.boxRect) < reach }.min { Grounding.distance(local, $0.boxRect) < Grounding.distance(local, $1.boxRect) }
            guard var inst = hit?.unmapped(from: region, scale: scale) else { continue }
            inst.id = id
            inst.objectId = nil
            return inst
        }
        return nil
    }

    /// Loads the accurate text recognition models, which otherwise take ~25 s on first use after a
    /// pause. Call at launch and every half minute while the app is in use.
    public static func warmUp() async {
        guard let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let image = ctx.makeImage() else { return }
        _ = await findText(["warm"], in: image, accurate: true)
    }

    /// The result of `work`, or nil if it takes longer than `seconds`. The work keeps running
    /// unwatched (Vision cannot be cancelled), so a task group, which waits for all its children,
    /// would not keep the budget.
    static func withBudget<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce(cont)
            Task { once.resume(await work()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.resume(nil)
            }
        }
    }

    /// Asks Spark which numbered candidate carries the printed text, on an enlarged crop.
    enum Verdict { case picked(SegmentInstance), noneOfThem, failed }

    func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = Double(i.width * i.height)
        return inter / (Double(a.width * a.height) + Double(b.width * b.height) - inter)
    }

    /// `point`: where the model pointed (image pixels), drawn as a yellow cross: with it the verifier
    /// can tell "the right one" of two look-alikes, which the words alone do not say.
    func verify(_ spec: TargetSpec, description: String? = nil, point: CGPoint? = nil, candidates: [SegmentInstance], in image: CGImage) async -> Verdict {
        let numbered = candidates.enumerated().map { $0.element.renumbered($0.offset + 1) }
        var area = numbered.reduce(CGRect.null) { $0.union($1.boxRect) }
        if let point { area = area.union(CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)) }
        let pad = max(area.width, area.height) * 0.25 + 12
        area = area.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        let zoom = min(3, 560 / max(area.width, area.height))
        guard let view = SetOfMarks.crop(image, to: area, scale: zoom),
              let outlined = SetOfMarks.render(view, instances: numbered.map { $0.mapped(into: area, scale: zoom) }),
              let marked = point.map({ p in SetOfMarks.cross(outlined, at: CGPoint(x: (p.x - area.minX) * zoom, y: (p.y - area.minY) * zoom)) }) ?? outlined,
              let jpeg = SetOfMarks.jpeg(marked, quality: 0.85) else { return .failed }
        let printed = spec.text.joined(separator: " / ")
        let pointed = point == nil ? "" : " The yellow cross is where the guide pointed; it may be a little off."
        let question: String
        if let description, spec.text.isEmpty {
            question = "A guide pointed at a \(spec.phrase) and said: \"\(description)\".\(pointed) Which numbered outline is the \(spec.phrase) the guide means? The numbers are labels next to the outlines; look at what is inside each outline. Answer with its number, or 0 if none of them is."
        } else if spec.text.isEmpty {
            question = "A guide pointed at a \(spec.phrase).\(pointed) Which numbered outline is that \(spec.phrase)? Answer with its number, or 0 if none of them is."
        } else {
            question = "Which numbered \(spec.phrase) has \(printed) printed on it? Read the printed characters on each numbered \(spec.phrase) carefully.\(pointed) Answer with its number, or 0 if none of them does."
        }
        // (Asking the verifier also for what it read on its pick did not help: on 1 Nov it chose
        // the escape key for "tab" and said it read "tab", and read the pause sign as "II" or "||".)
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["mark": .object(["type": .string("integer")])]),
            "required": .array([.string("mark")]),
            "additionalProperties": .bool(false),
        ])
        let request = ChatRequest(messages: [ChatMessage(role: .user, parts: [.text(question), .imageJPEG(jpeg)])], stream: false, reasoningEffort: .minimal,
                                  responseFormat: ResponseFormat(name: "pick", schema: schema))
        struct Pick: Decodable { var mark: Int }
        let answer = try? await client.chat(request)
        if let dir = ProcessInfo.processInfo.environment["PIP_DEBUG_DIR"] {
            try? jpeg.write(to: URL(fileURLWithPath: dir).appendingPathComponent("verify-\(Int(Date().timeIntervalSince1970 * 1000)).jpg"))
            print("verify:", question, "→", answer?.text ?? "error")
        }
        guard let (text, _) = answer, let pick = try? JSONDecoder().decode(Pick.self, from: Data(text.utf8)) else { return .failed }
        if pick.mark == 0 { return .noneOfThem }
        guard (1...candidates.count).contains(pick.mark) else { return .failed }
        return .picked(candidates[pick.mark - 1])
    }

    /// Boxes (in image pixels, top-left origin) of recognised text that matches one of the
    /// alternatives as whole words: "1F" does not match inside "11F", and a word found in a longer
    /// line ("esc f1 f2") gets the box of that word, not of the line.
    static func findText(_ wanted: [String], in image: CGImage, accurate: Bool) async -> [(rect: CGRect, length: Int)] {
        guard !wanted.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = accurate ? .accurate : .fast
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.01
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil, let observations = request.results else { return [] }
            let targets = Set(wanted.map(normalize).filter { !$0.isEmpty })
            let w = CGFloat(image.width), h = CGFloat(image.height)
            var boxes: [(rect: CGRect, length: Int)] = []
            for obs in observations {
                guard let candidate = obs.topCandidates(1).first else { continue }
                let line = candidate.string
                if ProcessInfo.processInfo.environment["PIP_DEBUG_OCR"] != nil {
                    let b = obs.boundingBox
                    print("OCR", line, String(format: "%.2f", candidate.confidence), Int(b.midX * w), Int((1 - b.midY) * h))
                }
                // Runs of one to three consecutive words, compared after normalising.
                let words = line.split(whereSeparator: { $0.isWhitespace }).map { $0.startIndex..<$0.endIndex }
                for i in words.indices {
                    for j in i..<min(i + 3, words.count) {
                        let range = words[i].lowerBound..<words[j].upperBound
                        let joined = normalize(String(line[range]))
                        guard targets.contains(joined) else { continue }
                        let b = (try? candidate.boundingBox(for: range))?.boundingBox ?? obs.boundingBox
                        boxes.append((CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h), joined.count))
                    }
                }
            }
            return boxes
        }.value
    }

    /// Lowercase, without spaces or dashes; words also without accents ("entrée" = "entree"), but
    /// single characters keep them, because "à" and "a" are different keys.
    static func normalize(_ s: String) -> String {
        let plain = s.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
        return plain.count >= 2 ? plain.folding(options: .diacriticInsensitive, locale: nil) : plain
    }
}

/// Whole-frame SAM results for each phrase, fetched once per look and shared by its targets.
actor WholeFrameSegments {
    private let client: PipClient
    private let jpeg: Data
    private var tasks: [String: Task<[SegmentInstance]?, Never>] = [:]

    init(client: PipClient, jpeg: Data) {
        self.client = client
        self.jpeg = jpeg
    }

    func instances(for phrase: String) async -> [SegmentInstance]? {
        if let task = tasks[phrase] { return await task.value }
        let client = client, jpeg = jpeg
        let task = Task { try? await client.segment(SegmentRequest(jpeg: jpeg, prompts: [phrase], minConfidence: 0.25, maxInstances: 200)).instances }
        tasks[phrase] = task
        return await task.value
    }
}

/// Resumes a continuation the first time only.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
