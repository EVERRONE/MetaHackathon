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
    /// Surface points, 4 cm apart, packed x, y, z (metres, this piece's frame).
    public var points: [Float]
    public var keyframes: [MapKeyframe]

    public init(id: UUID = UUID(), created: Date = Date()) {
        self.id = id
        self.created = created
        updated = created
        points = []
        keyframes = []
    }

    public var surface: [simd_float3] {
        stride(from: 0, to: points.count - 2, by: 3).map { simd_float3(points[$0], points[$0 + 1], points[$0 + 2]) }
    }

    public mutating func setSurface(_ pts: [simd_float3]) {
        points = pts.flatMap { [$0.x, $0.y, $0.z] }
    }

    /// Everything in this piece, moved into another frame by `t` (this frame → that frame).
    public func transformed(by t: simd_float4x4) -> MapPiece {
        var out = self
        out.setSurface(surface.map { (t * simd_float4($0, 1)).xyz })
        out.keyframes = keyframes.map { k in
            var k = k
            k.pose = t * k.pose
            return k
        }
        return out
    }
}

public struct MapKeyframe: Codable, Sendable {
    /// Camera pose (camera → piece frame), column-major.
    public var poseValues: [Float]
    /// Apple Vision image fingerprint of what the camera saw.
    public var print: [Float]
    public var time: Date

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
