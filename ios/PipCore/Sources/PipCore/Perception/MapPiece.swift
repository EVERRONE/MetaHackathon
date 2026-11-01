import Foundation
import simd

/// A piece of Pip's map of the user's home: one session's room, in its own coordinate frame, next
/// to ARKit's world map of it (stored apart, see MapStore). Built while Pip is used, no scanning.

/// A spot on earth from the phone's location (Wi-Fi and GPS), with its accuracy in metres.
public struct GeoPoint: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var accuracy: Double

    public init(latitude: Double, longitude: Double, accuracy: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
    }

    /// Metres along the earth's surface (haversine).
    public func distance(to o: GeoPoint) -> Double {
        let r = 6_371_000.0, rad = Double.pi / 180
        let dLat = (o.latitude - latitude) * rad, dLon = (o.longitude - longitude) * rad
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(latitude * rad) * cos(o.latitude * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    /// Whether two fixes can be the same home or building: within 150 m, or within twice their
    /// accuracies when those are worse (indoors a fix is often 20–100 m off).
    public func couldBeSamePlace(as o: GeoPoint) -> Bool {
        distance(to: o) <= max(150, 2 * (accuracy + o.accuracy))
    }
}

/// The light a room was mapped in, from ARKit's estimate: a map made under evening lamps is
/// rarely recognised in daylight (Apple: relocalising is "less likely when lighting conditions
/// have changed"), so the saved room whose light is most like now's is tried first.
public struct MapLight: Codable, Equatable, Sendable {
    /// ARKit's ambient intensity (lumen; 1000 is neutral).
    public var intensity: Double
    /// ARKit's ambient colour temperature (kelvin; daylight about 5000-6500, lamps 2700-3500).
    public var temperature: Double

    public init(intensity: Double, temperature: Double) {
        self.intensity = intensity
        self.temperature = temperature
    }

    /// How different two lights are: a doubling of brightness counts 1, 1500 K counts 1.
    public func distance(to o: MapLight) -> Double {
        abs(log2(max(intensity, 1) / max(o.intensity, 1))) + abs(temperature - o.temperature) / 1500
    }
}

public struct MapPiece: Codable, Sendable, Identifiable {
    public var id: UUID
    public var created: Date
    public var updated: Date
    public var keyframes: [MapKeyframe]
    /// Roughly where on earth the piece was mapped: tells another home or building apart, not
    /// rooms. nil in older pieces, and without location access.
    public var location: GeoPoint?
    /// The light it was mapped in (nil in older pieces).
    public var light: MapLight?

    public init(id: UUID = UUID(), created: Date = Date()) {
        self.id = id
        self.created = created
        updated = created
        keyframes = []
    }

    // Older pieces also hold surface points and image fingerprints, for linking pieces by their
    // surfaces (switched off on 31 Oct after 0 links in 43 tries, removed on 1 Nov): ignored.
    enum CodingKeys: String, CodingKey { case id, created, updated, keyframes, location, light }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        created = try c.decode(Date.self, forKey: .created)
        updated = try c.decode(Date.self, forKey: .updated)
        keyframes = try c.decode([MapKeyframe].self, forKey: .keyframes)
        location = try c.decodeIfPresent(GeoPoint.self, forKey: .location)
        light = try c.decodeIfPresent(MapLight.self, forKey: .light)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(created, forKey: .created)
        try c.encode(updated, forKey: .updated)
        try c.encode(keyframes, forKey: .keyframes)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(light, forKey: .light)
    }
}

/// Where the camera stood when the piece was mapped, every metre or so (camera → piece frame).
public struct MapKeyframe: Codable, Sendable {
    /// Column-major.
    public var poseValues: [Float]
    public var time: Date

    enum CodingKeys: String, CodingKey { case poseValues, time }

    public init(pose: simd_float4x4, time: Date = Date()) {
        poseValues = []
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

    public var position: simd_float3 { simd_float3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z) }
}
