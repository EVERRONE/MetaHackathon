#if arch(arm64)
import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation
import QuartzCore

/// Meta's EdgeTAM ("SAM 2 for the edge", facebookresearch/EdgeTAM, Apache-2.0) following one object
/// through live video on the Neural Engine, seeded with the object's mask.
///
/// The model comes as four Core ML packages (jutsuhq/edgetam-coreml v1.2, with the propagator that
/// masks the bank's empty slots):
/// - the image encoder, on every frame: a 1024² BGRA image (the upright camera image stretched to
///   a square, as SAM 2 does);
/// - the initializer and the memory encoder, once, on the seed frame: with a mask and no labelled
///   point it is SAM 2's mask prompt (the mask itself is the seed's output; its object pointer comes
///   from the decoder);
/// - the propagator, on every later frame: it finds the object from a bank of memories, as SAM 2
///   does: the seed in spatial slot 6 and the six previous frames in slots 0–5 (temporal rows 6 and
///   0–5), the seed's object pointer first and the 15 previous frames' after it. Empty slots stay
///   zero, which the masked propagator ignores.
public final class EdgeTAM: @unchecked Sendable {
    public static let side = 1024
    public static let names = ["EdgeTAMVideoImageEncoder", "EdgeTAMVideoInitializer", "EdgeTAMVideoMemoryEncoder", "EdgeTAMVideoPropagator"]
    static let slots = 7, tokens = 512, dim = 64, pointerSlots = 16, pointerDim = 256, lowSide = 256

    private let encoder: MLModel
    private let initializer: MLModel
    private let memoryEncoder: MLModel
    private let propagator: MLModel

    private struct Memory {
        var features: [Float16]   // 512 × 64
        var positions: [Float16]  // 512 × 64
        var pointer: [Float16]    // 256
    }

    private var seedMemory: Memory?
    /// Memories of the frames tracked since the seed, oldest first (at most 15).
    private var recent: [Memory] = []
    /// The temporal encoding added to a slot's positions, 7 × 64 (row k: k + 1 frames back for k < 6,
    /// row 6: the seed).
    private var temporal: [Float] = []
    private let spatialBank: MLMultiArray
    private let spatialPositions: MLMultiArray
    private let pointerBank: MLMultiArray
    private let attentionBias: MLMultiArray
    /// How long loading took (the first load on a device also compiles for the Neural Engine).
    public let loadSeconds: Double

    /// `folder` holds the compiled models (`.mlmodelc`), as Xcode puts them in the app.
    /// `encoderOnGPU`: the image encoder runs on the GPU, so it can work on the next frame while
    /// the propagator, on the Neural Engine, works on this one (see `encode` and `track(_:)`).
    public init(compiledIn folder: URL, encoderOnGPU: Bool = false) throws {
        let t0 = CACurrentMediaTime()
        func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let config = MLModelConfiguration()
            config.computeUnits = units
            return try MLModel(contentsOf: folder.appendingPathComponent(name + ".mlmodelc"), configuration: config)
        }
        encoder = try load(Self.names[0], encoderOnGPU ? .cpuAndGPU : .cpuAndNeuralEngine)
        // The initializer is fp32, which the Neural Engine does not run: the GPU (the CPU takes 4× longer).
        initializer = try load(Self.names[1], .all)
        memoryEncoder = try load(Self.names[2], .cpuAndNeuralEngine)
        propagator = try load(Self.names[3], .cpuAndNeuralEngine)
        let bank = [1, Self.slots, Self.tokens, Self.dim].map { NSNumber(value: $0) }
        spatialBank = try MLMultiArray(shape: bank, dataType: .float16)
        spatialPositions = try MLMultiArray(shape: bank, dataType: .float16)
        pointerBank = try MLMultiArray(shape: [1, Self.pointerSlots, Self.pointerDim].map { NSNumber(value: $0) }, dataType: .float16)
        attentionBias = try MLMultiArray(shape: [1, 1, 1, 3648], dataType: .float16)
        Self.zero(attentionBias)
        loadSeconds = CACurrentMediaTime() - t0
    }

    /// Compiles the packages in `packages` (`.mlpackage`) into `folder`, for tools on the Mac.
    public static func compile(packagesIn packages: URL, into folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            let dest = folder.appendingPathComponent(name + ".mlmodelc")
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            let compiled = try await MLModel.compileModel(at: packages.appendingPathComponent(name + ".mlpackage"))
            try FileManager.default.moveItem(at: compiled, to: dest)
        }
    }


    // MARK: Tracking

    /// One frame's answer. Coordinates are normalised (0…1) in the image given, y down.
    public struct Frame: @unchecked Sendable {
        /// Above 0: the object is in the frame.
        public let objectScore: Float
        public let iou: Float
        public let box: CGRect?
        public let centroid: CGPoint?
        /// Fraction of the image the mask covers.
        public let area: Double
        /// The mask at the decoder's resolution: 256², row-major, 1 = object.
        public let lowRes: [UInt8]
        /// The mask at full resolution (1024²) inside `cropRect` (pixels of the 1024² square).
        public let crop: [UInt8]
        public let cropRect: CGRect
        /// The object's outline from the full-resolution mask, normalised like `box`: smooth and
        /// 96 evenly spaced points (see `contour`).
        public let outline: [CGPoint]
        public let encodeMs: Double
        public let decodeMs: Double
        /// The parts of `decodeMs`: filling the memory bank, the propagator on the Neural Engine,
        /// and reading its output (masks, outline).
        public var bankMs = 0.0, propagateMs = 0.0, readMs = 0.0

        public var present: Bool { objectScore > 0 && box != nil }

        /// Whether a normalised point is on the object (at the decoder's resolution).
        public func contains(u: Double, v: Double) -> Bool {
            let x = Int(u * Double(EdgeTAM.lowSide)), y = Int(v * Double(EdgeTAM.lowSide))
            guard x >= 0, y >= 0, x < EdgeTAM.lowSide, y < EdgeTAM.lowSide else { return false }
            return lowRes[y * EdgeTAM.lowSide + x] != 0
        }
    }

    public enum Failure: Error { case notSeeded, missingOutput(String) }

    /// Starts following the object of `mask` (1024², row-major, nonzero = object) in `image` (a
    /// 1024² BGRA input, see `Input`). Forgets any earlier object.
    public func seed(image: CVPixelBuffer, mask: [UInt8]) throws -> Frame {
        precondition(mask.count == Self.side * Self.side)
        let t0 = CACurrentMediaTime()
        let features = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: image)]))
        let t1 = CACurrentMediaTime()
        let maskInput = try MLMultiArray(shape: [1, 1, 1024, 1024], dataType: .float16)
        maskInput.withUnsafeMutableBufferPointer(ofType: Float16.self) { p, _ in
            for i in 0..<mask.count { p[i] = mask[i] != 0 ? 1 : 0 }
        }
        // No labelled point: SAM 2's mask prompt.
        let coords = try MLMultiArray(shape: [1, 1, 2], dataType: .float16)
        Self.zero(coords)
        let labels = try MLMultiArray(shape: [1, 1], dataType: .int32)
        labels[0] = -1
        let out = try initializer.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "initial_vision_features": try value(features, "initial_vision_features"),
            "high_res_feature_0": try value(features, "high_res_feature_0"),
            "high_res_feature_1": try value(features, "high_res_feature_1"),
            "point_coords": MLFeatureValue(multiArray: coords),
            "point_labels": MLFeatureValue(multiArray: labels),
            "mask_input": MLFeatureValue(multiArray: maskInput),
        ]))
        // The memory of a prompted frame is made from the binarised mask, as SAM 2 does.
        let highRes = try array(out, "high_res_mask")
        let binary = try MLMultiArray(shape: [1, 1, 1024, 1024], dataType: .float16)
        let logits = Self.copy(highRes)
        binary.withUnsafeMutableBufferPointer(ofType: Float16.self) { p, _ in
            for i in 0..<logits.count { p[i] = logits[i] > 0 ? 30 : -30 }
        }
        let memory = try memoryEncoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "raw_vision_features": try value(features, "raw_vision_features"),
            "high_res_mask": MLFeatureValue(multiArray: binary),
            "object_score": try value(out, "object_score"),
        ]))
        temporal = Self.copy(try array(memory, "temporal_positions")).map(Float.init)
        seedMemory = Memory(features: Self.copy(try array(memory, "memory_features")),
                            positions: Self.copy(try array(memory, "memory_positions")),
                            pointer: Self.copy(try array(out, "object_pointer")))
        recent = []
        return try frame(out, encodeMs: (t1 - t0) * 1000, decodeMs: (CACurrentMediaTime() - t1) * 1000)
    }

    /// A frame's image features, ready for `track(_:)`.
    public struct Features: @unchecked Sendable {
        let provider: MLFeatureProvider
        public let encodeMs: Double
    }

    /// The image encoder alone: it does not touch the memory bank, so it may run on another
    /// thread while `track(_:)` works on the previous frame (with the encoder on the GPU, both
    /// run at the same time).
    public func encode(_ image: CVPixelBuffer) throws -> Features {
        let t0 = CACurrentMediaTime()
        let p = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: image)]))
        return Features(provider: p, encodeMs: (CACurrentMediaTime() - t0) * 1000)
    }

    /// The object in the next frame (`image`: a 1024² BGRA input).
    public func track(image: CVPixelBuffer) throws -> Frame {
        try track(try encode(image))
    }

    /// The object in the frame these features come from. Frames go in order, one at a time.
    public func track(_ encoded: Features) throws -> Frame {
        guard let seed = seedMemory else { throw Failure.notSeeded }
        let features = encoded.provider
        let t1 = CACurrentMediaTime()
        fillBank(seed: seed)
        let t2 = CACurrentMediaTime()
        let out = try propagator.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "raw_vision_features": try value(features, "raw_vision_features"),
            "high_res_feature_0": try value(features, "high_res_feature_0"),
            "high_res_feature_1": try value(features, "high_res_feature_1"),
            "spatial_bank": MLFeatureValue(multiArray: spatialBank),
            "spatial_positions": MLFeatureValue(multiArray: spatialPositions),
            "pointer_bank": MLFeatureValue(multiArray: pointerBank),
            "attention_bias": MLFeatureValue(multiArray: attentionBias),
        ]))
        let t3 = CACurrentMediaTime()
        recent.append(Memory(features: Self.copy(try array(out, "memory_features")),
                             positions: Self.copy(try array(out, "memory_positions")),
                             pointer: Self.copy(try array(out, "object_pointer"))))
        if recent.count > Self.pointerSlots - 1 { recent.removeFirst(recent.count - (Self.pointerSlots - 1)) }
        var f = try frame(out, encodeMs: encoded.encodeMs, decodeMs: (CACurrentMediaTime() - t1) * 1000)
        f.bankMs = (t2 - t1) * 1000
        f.propagateMs = (t3 - t2) * 1000
        f.readMs = (CACurrentMediaTime() - t3) * 1000
        return f
    }

    /// Takes the last tracked frame out of the memory bank: its mask was on something else (see
    /// TrackGate), and remembering it would make EdgeTAM follow that from then on.
    public func forgetLatest() {
        if !recent.isEmpty { recent.removeLast() }
    }

    private func fillBank(seed: Memory) {
        let slotSize = Self.tokens * Self.dim
        let temporal = self.temporal
        spatialBank.withUnsafeMutableBufferPointer(ofType: Float16.self) { bank, _ in
            spatialPositions.withUnsafeMutableBufferPointer(ofType: Float16.self) { pos, _ in
                bank.initialize(repeating: 0)
                pos.initialize(repeating: 0)
                func place(_ m: Memory, slot: Int, row: Int) {
                    let base = slot * slotSize
                    for i in 0..<slotSize { bank[base + i] = m.features[i] }
                    for t in 0..<Self.tokens {
                        for d in 0..<Self.dim {
                            let i = t * Self.dim + d
                            pos[base + i] = Float16(Float(m.positions[i]) + temporal[row * Self.dim + d])
                        }
                    }
                }
                place(seed, slot: Self.slots - 1, row: Self.slots - 1)
                for (back, m) in recent.reversed().prefix(Self.slots - 1).enumerated() { place(m, slot: back, row: back) }
            }
        }
        pointerBank.withUnsafeMutableBufferPointer(ofType: Float16.self) { p, _ in
            p.initialize(repeating: 0)
            for i in 0..<Self.pointerDim { p[i] = seed.pointer[i] }
            for (k, m) in recent.reversed().prefix(Self.pointerSlots - 1).enumerated() {
                for i in 0..<Self.pointerDim { p[(k + 1) * Self.pointerDim + i] = m.pointer[i] }
            }
        }
    }

    /// Box, centre, area and masks from a decoder's output.
    private func frame(_ out: MLFeatureProvider, encodeMs: Double, decodeMs: Double) throws -> Frame {
        let score = Float(Self.copy(try array(out, "object_score")).first ?? -1)
        let iou = Float(Self.copy(try array(out, "best_iou")).first ?? 0)
        let low = Self.copy(try array(out, "low_res_mask"))
        let n = Self.lowSide
        var lowRes = [UInt8](repeating: 0, count: n * n)
        var minX = n, minY = n, maxX = -1, maxY = -1
        for y in 0..<n {
            for x in 0..<n where low[y * n + x] > 0 {
                lowRes[y * n + x] = 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard score > 0, maxX >= 0 else {
            return Frame(objectScore: score, iou: iou, box: nil, centroid: nil, area: 0, lowRes: lowRes, crop: [], cropRect: .zero, outline: [],
                         encodeMs: encodeMs, decodeMs: decodeMs)
        }
        // The full-resolution mask only around the object (the low-res box, a little wider).
        let s = Self.side / n
        let x0 = max(0, (minX - 2) * s), y0 = max(0, (minY - 2) * s)
        let x1 = min(Self.side, (maxX + 3) * s), y1 = min(Self.side, (maxY + 3) * s)
        let high = try array(out, "high_res_mask")
        var crop = [UInt8](repeating: 0, count: (x1 - x0) * (y1 - y0))
        var count = 0, sumX = 0.0, sumY = 0.0
        var bx0 = Self.side, by0 = Self.side, bx1 = -1, by1 = -1
        high.withUnsafeBufferPointer(ofType: Float16.self) { p in
            let rowStride = high.strides[2].intValue, colStride = high.strides[3].intValue
            for y in y0..<y1 {
                for x in x0..<x1 where p[y * rowStride + x * colStride] > 0 {
                    crop[(y - y0) * (x1 - x0) + (x - x0)] = 1
                    count += 1; sumX += Double(x); sumY += Double(y)
                    bx0 = min(bx0, x); bx1 = max(bx1, x); by0 = min(by0, y); by1 = max(by1, y)
                }
            }
        }
        let side = Double(Self.side)
        let box = count > 0 ? CGRect(x: Double(bx0) / side, y: Double(by0) / side, width: Double(bx1 - bx0 + 1) / side, height: Double(by1 - by0 + 1) / side) : nil
        let centroid = count > 0 ? CGPoint(x: (sumX / Double(count) + 0.5) / side, y: (sumY / Double(count) + 0.5) / side) : nil
        let outline = count > 0 ? Self.contour(crop, width: x1 - x0, height: y1 - y0).map { CGPoint(x: (Double(x0) + $0.x) / side, y: (Double(y0) + $0.y) / side) } : []
        return Frame(objectScore: score, iou: iou, box: box, centroid: centroid, area: Double(count) / (side * side), lowRes: lowRes,
                     crop: crop, cropRect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), outline: outline,
                     encodeMs: encodeMs, decodeMs: decodeMs)
    }

    // MARK: Outline

    /// The outer boundary of the largest region of a binary mask (row-major, nonzero = in), through
    /// its boundary pixels' centres, simplified to within `tolerance` pixels: the object's outline as
    /// the mask draws it, with its pixel steps.
    public static func outline(_ mask: [UInt8], width w: Int, height h: Int, tolerance: Double = 1.0, maxPoints: Int = 80) -> [CGPoint] {
        let points = trace(mask, width: w, height: h)
        guard points.count > 3 else { return points }
        var tol = tolerance
        var simple = simplify(points, tolerance: tol)
        while simple.count > maxPoints {
            tol *= 1.5
            simple = simplify(points, tolerance: tol)
        }
        return simple
    }

    /// The edge the mask's pixel steps approximate: the traced boundary smoothed over about
    /// `sigma` pixels and resampled to `count` evenly spaced points (the same count for every mask,
    /// so one outline can morph into the next; see Contour).
    public static func contour(_ mask: [UInt8], width w: Int, height h: Int, count: Int = 96, sigma: Double = 2) -> [CGPoint] {
        let points = trace(mask, width: w, height: h)
        guard points.count >= 3 else { return points }
        // Boundary pixels are about a pixel apart: n binomial passes have a variance of n / 2.
        let passes = max(1, Int((2 * sigma * sigma).rounded()))
        let soft = Contour.smooth(points.map { SIMD2<Double>(Double($0.x), Double($0.y)) }, passes: passes)
        return Contour.resample(soft, count: count).map { CGPoint(x: $0.x, y: $0.y) }
    }

    /// The outer boundary of the largest 8-connected region, through its boundary pixels' centres
    /// (Moore neighbours, Jacob's stop), clockwise with y down.
    public static func trace(_ mask: [UInt8], width w: Int, height h: Int) -> [CGPoint] {
        guard w > 0, h > 0, mask.count == w * h else { return [] }
        // The largest 8-connected region.
        var label = [Int32](repeating: 0, count: w * h)
        var best: Int32 = 0, bestSize = 0, next: Int32 = 0
        var stack: [Int] = []
        for i in 0..<(w * h) where mask[i] != 0 && label[i] == 0 {
            next += 1
            var size = 0
            label[i] = next
            stack.append(i)
            while let p = stack.popLast() {
                size += 1
                let x = p % w, y = p / w
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        let q = ny * w + nx
                        if mask[q] != 0, label[q] == 0 {
                            label[q] = next
                            stack.append(q)
                        }
                    }
                }
            }
            if size > bestSize { bestSize = size; best = next }
        }
        guard bestSize > 0, let start = label.firstIndex(of: best) else { return [] }
        func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && label[y * w + x] == best }
        // Clockwise with y down: E, SE, S, SW, W, NW, N, NE.
        let dirs = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
        let sx = start % w, sy = start / w
        // The first pixel in raster order: its west neighbour is outside.
        func step(from x: Int, _ y: Int, back: Int) -> (x: Int, y: Int, dir: Int, back: Int)? {
            for k in 1...8 {
                let d = (back + k) % 8
                let nx = x + dirs[d].0, ny = y + dirs[d].1
                // The neighbour looked at just before, seen from the new pixel.
                if inside(nx, ny) { return (nx, ny, d, d % 2 == 0 ? (d + 6) % 8 : (d + 5) % 8) }
            }
            return nil
        }
        guard let first = step(from: sx, sy, back: 4) else {
            return [CGPoint(x: Double(sx) + 0.5, y: Double(sy) + 0.5)]
        }
        var points = [CGPoint(x: Double(sx) + 0.5, y: Double(sy) + 0.5)]
        var cur = first
        let limit = 4 * w * h + 8
        var steps = 0
        while steps < limit {
            steps += 1
            if cur.x == sx, cur.y == sy {
                // Back at the start: done when the next move is the first one again (Jacob).
                guard let n = step(from: cur.x, cur.y, back: cur.back), n.dir != first.dir || n.x != first.x || n.y != first.y else { break }
                points.append(CGPoint(x: Double(cur.x) + 0.5, y: Double(cur.y) + 0.5))
                cur = n
                continue
            }
            points.append(CGPoint(x: Double(cur.x) + 0.5, y: Double(cur.y) + 0.5))
            guard let n = step(from: cur.x, cur.y, back: cur.back) else { break }
            cur = n
        }
        return points
    }

    /// Ramer–Douglas–Peucker on a closed ring (split at the point farthest from the first).
    static func simplify(_ ring: [CGPoint], tolerance: Double) -> [CGPoint] {
        guard ring.count > 3 else { return ring }
        let far = ring.indices.max { hypot(ring[$0].x - ring[0].x, ring[$0].y - ring[0].y) < hypot(ring[$1].x - ring[0].x, ring[$1].y - ring[0].y) } ?? 0
        guard far > 0 else { return [ring[0]] }
        func rdp(_ a: Int, _ b: Int, _ out: inout [CGPoint]) {
            let p = ring[a], q = ring[b % ring.count]
            var worst = -1.0, at = -1
            let dx = q.x - p.x, dy = q.y - p.y, len = max(hypot(dx, dy), 1e-9)
            if b - a > 1 {
                for i in (a + 1)..<b {
                    let r = ring[i % ring.count]
                    let d = abs(dy * (r.x - p.x) - dx * (r.y - p.y)) / len
                    if d > worst { worst = d; at = i }
                }
            }
            if worst > tolerance, at > a {
                rdp(a, at, &out)
                rdp(at, b, &out)
            } else {
                out.append(p)
            }
        }
        var out: [CGPoint] = []
        rdp(0, far, &out)
        rdp(far, ring.count, &out)
        return out
    }

    // MARK: Arrays

    private func value(_ p: MLFeatureProvider, _ name: String) throws -> MLFeatureValue {
        guard let v = p.featureValue(for: name) else { throw Failure.missingOutput(name) }
        return v
    }

    private func array(_ p: MLFeatureProvider, _ name: String) throws -> MLMultiArray {
        guard let a = p.featureValue(for: name)?.multiArrayValue else { throw Failure.missingOutput(name) }
        return a
    }

    static func zero(_ a: MLMultiArray) {
        switch a.dataType {
        case .float16: a.withUnsafeMutableBufferPointer(ofType: Float16.self) { p, _ in p.initialize(repeating: 0) }
        case .int32: a.withUnsafeMutableBufferPointer(ofType: Int32.self) { p, _ in p.initialize(repeating: 0) }
        default: for i in 0..<a.count { a[i] = 0 }
        }
    }

    /// An fp16 array's values in row-major order, whatever its strides (outputs of the Neural Engine
    /// can have padded rows).
    static func copy(_ a: MLMultiArray) -> [Float16] {
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
        var out = [Float16](repeating: 0, count: shape.reduce(1, *))
        guard !out.isEmpty else { return out }
        // Row-major without padding (the usual case): one copy.
        var expected = 1, dense = true
        for k in stride(from: shape.count - 1, through: 0, by: -1) {
            if shape[k] > 1, strides[k] != expected { dense = false; break }
            expected *= shape[k]
        }
        if dense {
            a.withUnsafeBufferPointer(ofType: Float16.self) { p in
                out.withUnsafeMutableBufferPointer { o in
                    if let src = p.baseAddress, let dst = o.baseAddress { dst.update(from: src, count: o.count) }
                }
            }
            return out
        }
        a.withUnsafeBufferPointer(ofType: Float16.self) { p in
            var index = [Int](repeating: 0, count: shape.count)
            for i in 0..<out.count {
                var offset = 0
                for k in 0..<shape.count { offset += index[k] * strides[k] }
                out[i] = p[offset]
                var k = shape.count - 1
                while k >= 0 {
                    index[k] += 1
                    if index[k] < shape[k] { break }
                    index[k] = 0
                    k -= 1
                }
            }
        }
        return out
    }

    // MARK: Inputs

    /// Turns camera frames and snapshots into the encoder's 1024² BGRA input: upright, stretched to
    /// the square, and rasterises object masks the same way.
    public final class Input: @unchecked Sendable {
        private let context = CIContext(options: [.cacheIntermediates: false])
        private var pool: CVPixelBufferPool?

        public init() {}

        /// A camera frame in sensor orientation, turned by `orientation` (`.right` for a portrait iPhone).
        public func image(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CVPixelBuffer? {
            render(CIImage(cvPixelBuffer: buffer).oriented(orientation))
        }

        /// An upright image (a snapshot).
        public func image(_ image: CGImage) -> CVPixelBuffer? {
            render(CIImage(cgImage: image))
        }

        private func render(_ image: CIImage) -> CVPixelBuffer? {
            let e = image.extent
            guard e.width > 0, e.height > 0, let out = buffer() else { return nil }
            let side = CGFloat(EdgeTAM.side)
            // Bilinear: the Lanczos filter took about 10 ms a frame on an iPhone 15 Pro (31 Oct).
            let scaled = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
                .concatenating(CGAffineTransform(scaleX: side / e.width, y: side / e.height)))
            // Exactly the square.
            context.render(scaled.cropped(to: CGRect(x: 0, y: 0, width: side, height: side)), to: out, bounds: CGRect(x: 0, y: 0, width: side, height: side),
                           colorSpace: CGColorSpaceCreateDeviceRGB())
            return out
        }

        private func buffer() -> CVPixelBuffer? {
            if pool == nil {
                let attrs: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey: EdgeTAM.side, kCVPixelBufferHeightKey: EdgeTAM.side,
                    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                ]
                CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            }
            guard let pool else { return nil }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            return pb
        }

        /// An object's outer contours (`polygons` in pixels of an upright image of `size`, as SAM's
        /// instances give them) as the seed mask.
        public static func mask(polygons: [[CGPoint]], in size: CGSize) -> [UInt8] {
            let side = EdgeTAM.side
            var px = [UInt8](repeating: 0, count: side * side)
            px.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                // Image rows grow downwards; the context's y grows upwards.
                ctx.translateBy(x: 0, y: CGFloat(side))
                ctx.scaleBy(x: CGFloat(side) / size.width, y: -CGFloat(side) / size.height)
                ctx.setFillColor(gray: 1, alpha: 1)
                for ring in polygons where ring.count >= 3 {
                    ctx.addLines(between: ring)
                    ctx.closePath()
                }
                // Outer contours only: where two overlap, both fill.
                ctx.fillPath(using: .winding)
            }
            return px.map { $0 > 127 ? 1 : 0 }
        }
    }
}
#endif
