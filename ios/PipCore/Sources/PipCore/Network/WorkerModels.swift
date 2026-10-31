import CoreGraphics
import Foundation

// Wire types for the Pip Worker (see worker/README.md).

public struct SegmentObjectPrompt: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var negative: Bool?
        public init(x: Int, y: Int, negative: Bool? = nil) { self.x = x; self.y = y; self.negative = negative }
    }

    public var id: Int
    /// Half-open pixel box [left, top, right, bottom].
    public var box: [Int]?
    public var points: [Point]?

    public init(id: Int, box: [Int]? = nil, points: [Point]? = nil) {
        self.id = id
        self.box = box
        self.points = points
    }
}

public struct SegmentRequest: Codable, Equatable, Sendable {
    /// JPEG as a data URL.
    public var image: String
    public var prompts: [String]?
    public var objects: [SegmentObjectPrompt]?
    public var width: Int?
    public var height: Int?
    public var minConfidence: Double?
    public var maxInstances: Int?

    public init(jpeg: Data, prompts: [String]? = nil, objects: [SegmentObjectPrompt]? = nil, width: Int? = nil, height: Int? = nil, minConfidence: Double? = nil, maxInstances: Int? = nil) {
        self.image = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        self.prompts = prompts
        self.objects = objects
        self.width = width
        self.height = height
        self.minConfidence = minConfidence
        self.maxInstances = maxInstances
    }
}

/// One object SAM found, as a numbered mark.
public struct SegmentInstance: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var prompts: [String]
    public var objectId: Int?
    public var confidence: Double
    /// Half-open pixel box [left, top, right, bottom].
    public var box: [Int]
    public var area: Int
    public var centroid: [Int]
    /// Outer contours as flat [x0, y0, x1, y1, …], largest first.
    public var polygons: [[Int]]
    public var contains: [Int]?

    public init(id: Int, prompts: [String], objectId: Int? = nil, confidence: Double, box: [Int], area: Int, centroid: [Int], polygons: [[Int]], contains: [Int]? = nil) {
        self.id = id
        self.prompts = prompts
        self.objectId = objectId
        self.confidence = confidence
        self.box = box
        self.area = area
        self.centroid = centroid
        self.polygons = polygons
        self.contains = contains
    }

    /// The contours as point lists in image pixels.
    public var outlinePoints: [[CGPoint]] {
        polygons.map { flat -> [CGPoint] in
            stride(from: 0, to: flat.count - 1, by: 2).map { i -> CGPoint in
                CGPoint(x: CGFloat(flat[i]), y: CGFloat(flat[i + 1]))
            }
        }
    }

    public var boxRect: CGRect {
        CGRect(x: CGFloat(box[0]), y: CGFloat(box[1]), width: CGFloat(box[2] - box[0]), height: CGFloat(box[3] - box[1]))
    }

    public var centre: CGPoint { CGPoint(x: CGFloat(centroid[0]), y: CGFloat(centroid[1])) }
}

public struct SegmentResponse: Codable, Equatable, Sendable {
    public struct Call: Codable, Equatable, Sendable {
        public var prompt: String
        public var found: Int
        public var ms: Int
    }

    public var width: Int?
    public var height: Int?
    public var instances: [SegmentInstance]
    public var calls: [Call]
    public var dropped: Int
}

public struct Transcript: Codable, Equatable, Sendable {
    public var transcript: String
}

public struct UsageStatus: Codable, Equatable, Sendable {
    public var today: Double
    public var total: Double
}

public struct WorkerError: Error, Equatable, Sendable, CustomStringConvertible {
    public var status: Int
    public var code: String
    public var message: String
    public var description: String { "\(status) \(code): \(message)" }
}

/// One sentence of synthesised speech.
public struct SpokenAudio: Sendable {
    /// 24 kHz, 16-bit, mono, little-endian.
    public var pcm: Data
    public var characters: [String]
    /// Start time of each character, in seconds from the start of the sentence.
    public var starts: [Double]

    public static let sampleRate = 24_000.0

    public var duration: Double { Double(pcm.count / 2) / Self.sampleRate }

    /// Start time of the character at a UTF-16 offset in `text` (the cue anchors are UTF-16).
    public func startTime(atUTF16 offset: Int, in text: String) -> Double? {
        guard !starts.isEmpty else { return nil }
        let prefix = String(decoding: Array(text.utf16.prefix(offset)), as: UTF16.self)
        let index = min(prefix.count, starts.count - 1)
        return starts[max(0, index)]
    }
}
