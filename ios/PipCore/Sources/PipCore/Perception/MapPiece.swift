import Foundation
import simd

/// A piece of Pip's map of the user's home: what one or more sessions saw, in that piece's own
/// coordinate frame. Built while Pip is used (no scanning): the room's surfaces from ARKit's
/// mesh, and every metre or so a map keyframe with an image fingerprint and the camera pose.
/// When a session recognises another piece, the two are linked into one frame and merged.
public struct MapPiece: Codable, Sendable, Identifiable {
    public var id: UUID
    public var created: Date
    public var updated: Date
    /// Surface points, 2.5 cm apart (each the average of the LiDAR mesh in its cube), packed
    /// x, y, z (metres, this piece's frame).
    public var points: [Float]
    /// The mesh's surface normal at each point, packed like `points` (nil in older pieces).
    public var normals: [Float]?
    /// ARKit's class of the surface at each point (`SurfaceClass`; nil in older pieces).
    public var classes: [UInt8]?
    public var keyframes: [MapKeyframe]

    public init(id: UUID = UUID(), created: Date = Date()) {
        self.id = id
        self.created = created
        updated = created
        points = []
        keyframes = []
    }

    // The surfaces are not in the JSON (hundreds of thousands of points): they go in a compact
    // binary file of their own (`surfaceData`). Older pieces with points in the JSON still load.
    enum CodingKeys: String, CodingKey { case id, created, updated, points, normals, classes, keyframes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        created = try c.decode(Date.self, forKey: .created)
        updated = try c.decode(Date.self, forKey: .updated)
        points = try c.decodeIfPresent([Float].self, forKey: .points) ?? []
        normals = try c.decodeIfPresent([Float].self, forKey: .normals)
        classes = try c.decodeIfPresent([UInt8].self, forKey: .classes)
        keyframes = try c.decode([MapKeyframe].self, forKey: .keyframes)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(created, forKey: .created)
        try c.encode(updated, forKey: .updated)
        try c.encode(keyframes, forKey: .keyframes)
    }

    /// 16 bytes a point: position (3 × Float32), normal (3 × Int8, ×127), class (UInt8).
    public func surfaceData() -> Data {
        let pts = surface
        let ns = surfaceNormals ?? Array(repeating: .zero, count: pts.count)
        let cs = classes.flatMap { $0.count == pts.count ? $0 : nil } ?? Array(repeating: 0, count: pts.count)
        var data = Data(capacity: 8 + pts.count * 16)
        data.append(contentsOf: Array("PIPS".utf8))
        var count = UInt32(pts.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        for i in pts.indices {
            for v in [pts[i].x, pts[i].y, pts[i].z] {
                var bits = v.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
            for v in [ns[i].x, ns[i].y, ns[i].z] { data.append(UInt8(bitPattern: Int8(max(-127, min(127, (v * 127).rounded()))))) }
            data.append(cs[i])
        }
        return data
    }

    public mutating func loadSurface(_ data: Data) {
        guard data.count >= 8, data.prefix(4) == Data("PIPS".utf8) else { return }
        let count = Int(data.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard data.count >= 8 + count * 16 else { return }
        var pts: [simd_float3] = [], ns: [simd_float3] = [], cs: [UInt8] = []
        pts.reserveCapacity(count); ns.reserveCapacity(count); cs.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let o = 8 + i * 16
                let f = { (k: Int) in Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o + k * 4, as: UInt32.self))) }
                pts.append(simd_float3(f(0), f(1), f(2)))
                let n = { (k: Int) in Float(Int8(bitPattern: raw[o + 12 + k])) / 127 }
                ns.append(simd_float3(n(0), n(1), n(2)))
                cs.append(raw[o + 15])
            }
        }
        setSurface(pts, normals: ns, classes: cs)
    }

    /// Merges surfaces into this piece: one averaged point per `size` cube, with normal and class.
    public mutating func addSurface(_ pts: [simd_float3], normals: [simd_float3]?, classes: [UInt8]?, size: Float = 0.025, limit: Int = 400_000) {
        let old = surface
        let oldNormals = surfaceNormals ?? Array(repeating: .zero, count: old.count)
        let oldClasses = self.classes.flatMap { $0.count == old.count ? $0 : nil } ?? Array(repeating: 0, count: old.count)
        let newNormals = normals.flatMap { $0.count == pts.count ? $0 : nil } ?? Array(repeating: .zero, count: pts.count)
        let newClasses = classes.flatMap { $0.count == pts.count ? $0 : nil } ?? Array(repeating: 0, count: pts.count)
        var merged = VoxelIndex.average(old + pts, normals: oldNormals + newNormals, classes: oldClasses + newClasses, size: size)
        if merged.points.count > limit {
            merged = VoxelIndex.average(merged.points, normals: merged.normals, classes: merged.classes, size: size * 1.4)
        }
        setSurface(merged.points, normals: merged.normals, classes: merged.classes)
    }

    public var surface: [simd_float3] {
        stride(from: 0, to: points.count - 2, by: 3).map { simd_float3(points[$0], points[$0 + 1], points[$0 + 2]) }
    }

    public mutating func setSurface(_ pts: [simd_float3], normals n: [simd_float3]? = nil, classes c: [UInt8]? = nil) {
        points = pts.flatMap { [$0.x, $0.y, $0.z] }
        normals = n.map { $0.flatMap { [$0.x, $0.y, $0.z] } }
        classes = c
    }

    public var surfaceNormals: [simd_float3]? {
        guard let normals, normals.count == points.count else { return nil }
        return stride(from: 0, to: normals.count - 2, by: 3).map { simd_float3(normals[$0], normals[$0 + 1], normals[$0 + 2]) }
    }

    /// The piece's surfaces ready for fitting: furniture that may move counts less.
    public func registrationTarget() -> RegistrationTarget {
        let weights = classes.flatMap { $0.count * 3 == points.count ? $0.map(SurfaceClass.weight) : nil }
        return RegistrationTarget(points: surface, normals: surfaceNormals, weights: weights)
    }

    /// Everything in this piece, moved into another frame by `t` (this frame → that frame).
    public func transformed(by t: simd_float4x4) -> MapPiece {
        var out = self
        out.setSurface(surface.map { (t * simd_float4($0, 1)).xyz }, normals: surfaceNormals?.map { (t * simd_float4($0, 0)).xyz }, classes: classes)
        out.keyframes = keyframes.map { k in
            var k = k
            k.pose = t * k.pose
            return k
        }
        return out
    }
}

/// ARKit's mesh classification, and how much each kind counts when laying rooms onto each other:
/// structure that never moves fully, furniture that may have been moved less.
public enum SurfaceClass {
    // ARMeshClassification raw values.
    public static let none: UInt8 = 0, wall: UInt8 = 1, floor: UInt8 = 2, ceiling: UInt8 = 3, table: UInt8 = 4
    public static let seat: UInt8 = 5, window: UInt8 = 6, door: UInt8 = 7

    public static func weight(_ c: UInt8) -> Float {
        switch c {
        case wall, floor, ceiling, door, window: return 1
        case table: return 0.6
        case seat: return 0.2
        default: return 0.35
        }
    }
}

public struct MapKeyframe: Codable, Sendable {
    /// Camera pose (camera → piece frame), column-major.
    public var poseValues: [Float]
    /// Apple Vision image fingerprint of what the camera saw.
    public var print: [Float]
    public var time: Date

    enum CodingKeys: String, CodingKey { case poseValues, print, printData, time }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        poseValues = try c.decode([Float].self, forKey: .poseValues)
        time = try c.decode(Date.self, forKey: .time)
        if let data = try c.decodeIfPresent(Data.self, forKey: .printData) {
            print = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        } else {
            print = try c.decodeIfPresent([Float].self, forKey: .print) ?? []
        }
    }

    /// The fingerprint as raw bytes (a quarter of the size of a JSON number list).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(poseValues, forKey: .poseValues)
        try c.encode(time, forKey: .time)
        try c.encode(print.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .printData)
    }

    public init(pose: simd_float4x4, print: [Float], time: Date = Date()) {
        poseValues = []
        self.print = print
        self.time = time
        self.pose = pose
    }

    public var pose: simd_float4x4 {
        get {
            guard poseValues.count == 16 else { return matrix_identity_float4x4 }
            let c = { (i: Int) in simd_float4(self.poseValues[i * 4], self.poseValues[i * 4 + 1], self.poseValues[i * 4 + 2], self.poseValues[i * 4 + 3]) }
            return simd_float4x4(columns: (c(0), c(1), c(2), c(3)))
        }
        set {
            poseValues = [newValue.columns.0, newValue.columns.1, newValue.columns.2, newValue.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
        }
    }

    public var position: simd_float3 { pose.columns.3.xyz }
}

/// Image fingerprints: how alike two views look (Euclidean distance; smaller is more alike).
public enum FeaturePrint {
    public static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var sum: Float = 0
        for i in a.indices {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum.squareRoot()
    }

    /// The keyframes of other pieces that look most like `print`, best first.
    public static func candidates(for print: [Float], in pieces: [MapPiece], limit: Int = 3, maxDistance: Float) -> [(piece: UUID, keyframe: Int, distance: Float)] {
        var out: [(UUID, Int, Float)] = []
        for piece in pieces {
            for (i, k) in piece.keyframes.enumerated() {
                let d = distance(print, k.print)
                if d <= maxDistance { out.append((piece.id, i, d)) }
            }
        }
        return out.sorted { $0.2 < $1.2 }.prefix(limit).map { ($0.0, $0.1, $0.2) }
    }
}

/// Decides when two map pieces may be linked: only when two fits from clearly different places
/// (half a metre apart, or 20 degrees round) agree within 5 cm and 2 degrees, each of them a
/// good, unambiguous fit. A wrong link is worse than none.
public struct LinkConsensus: Sendable {
    struct Fit: Sendable {
        var transform: simd_float4x4
        var yaw: Float
        var camera: simd_float3
        var heading: Float
        var time: Double
    }

    private var fits: [UUID: [Fit]] = [:]
    public static let agreeDistance: Float = 0.05
    public static let agreeDegrees: Float = 2
    public static let minSeparation: Float = 0.5
    public static let minTurnDegrees: Float = 20
    public static let window: Double = 120

    public init() {}

    /// Adds a fit of the live session (`transform`: live frame → that piece's frame) made with the
    /// camera at `camera`. Returns the link when an earlier fit from elsewhere agrees.
    public mutating func add(piece: UUID, fit: PointRegistration.Result, camera: simd_float4x4, time: Double) -> simd_float4x4? {
        guard fit.isMatch else { return nil }
        let new = Fit(transform: fit.transform, yaw: fit.yawDegrees, camera: camera.columns.3.xyz,
                      heading: PointRegistration.yaw(of: camera) * 180 / .pi, time: time)
        var list = (fits[piece] ?? []).filter { time - $0.time < Self.window }
        defer {
            list.append(new)
            fits[piece] = Array(list.suffix(6))
        }
        for old in list {
            let apart = simd_distance(old.camera, new.camera) >= Self.minSeparation || Self.angle(old.heading, new.heading) >= Self.minTurnDegrees
            guard apart else { continue }
            // Agreement where it matters: the same live point lands in the same place.
            let probe = simd_float4(new.camera, 1)
            let a = (old.transform * probe).xyz, b = (new.transform * probe).xyz
            if simd_distance(a, b) < Self.agreeDistance, Self.angle(old.yaw, new.yaw) < Self.agreeDegrees {
                let yaw = (old.yaw + Self.wrapped(new.yaw - old.yaw) / 2) * .pi / 180
                let t = (old.transform.columns.3.xyz + new.transform.columns.3.xyz) / 2
                return PointRegistration.transform(yaw: yaw, translation: t)
            }
        }
        return nil
    }

    public mutating func forget(_ piece: UUID) { fits[piece] = nil }

    static func wrapped(_ degrees: Float) -> Float {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    static func angle(_ a: Float, _ b: Float) -> Float { abs(wrapped(a - b)) }
}
