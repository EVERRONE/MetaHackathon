import CoreGraphics
import PipCore
import simd

/// A SAM instance lifted into 3D, so its outline stays on the object while the phone moves.
///
/// The outline is placed on a plane facing the camera at the object's median LiDAR depth.
/// That is exact for flat parts seen head-on and close enough for small objects.
struct AnchoredMark {
    let id: Int
    let polygons: [[simd_float3]]
    let centroid: simd_float3
    /// Distance from the camera at capture time, in metres.
    let depth: Float
    /// Image-space size of the instance, for arrow length.
    let imageExtent: CGFloat
    private let unproject: (CGPoint) -> simd_float3
    private let imageCentre: CGPoint

    init?(_ instance: SegmentInstance, snapshot: FrameSnapshot) {
        guard let outer = instance.outlinePoints.first, outer.count >= 3 else { return nil }
        guard let d = Self.medianDepth(instance, outer: outer, snapshot: snapshot) else { return nil }
        let unproject = { (p: CGPoint) in snapshot.worldPoint(sensor: snapshot.sensorPoint(p), depth: d) }
        id = instance.id
        depth = d
        polygons = instance.outlinePoints.map { $0.map(unproject) }
        centroid = unproject(instance.centre)
        imageCentre = instance.centre
        imageExtent = max(instance.boxRect.width, instance.boxRect.height)
        self.unproject = unproject
    }

    /// Start and end of a straight arrow for `move`, in world space.
    func arrow(_ direction: MoveDirection) -> (simd_float3, simd_float3) {
        let len = max(40, imageExtent * 0.55)
        let (dx, dy): (CGFloat, CGFloat)
        switch direction {
        case .up: (dx, dy) = (0, -1)
        case .down: (dx, dy) = (0, 1)
        case .left: (dx, dy) = (-1, 0)
        case .right: (dx, dy) = (1, 0)
        case .in, .out: (dx, dy) = (0, 0)
        }
        let end = CGPoint(x: imageCentre.x + dx * len, y: imageCentre.y + dy * len)
        return (centroid, unproject(end))
    }

    /// Median depth of the instance's interior, preferring confident LiDAR samples.
    private static func medianDepth(_ instance: SegmentInstance, outer: [CGPoint], snapshot: FrameSnapshot) -> Float? {
        let box = instance.boxRect
        let n = 14
        for minConfidence: UInt8 in [1, 0] {
            var samples: [Float] = []
            for i in 0..<n {
                for j in 0..<n {
                    let p = CGPoint(x: box.minX + (CGFloat(i) + 0.5) / CGFloat(n) * box.width,
                                    y: box.minY + (CGFloat(j) + 0.5) / CGFloat(n) * box.height)
                    guard contains(outer, p), let d = snapshot.depth(atSensor: snapshot.sensorPoint(p), minConfidence: minConfidence) else { continue }
                    samples.append(d)
                }
            }
            if samples.count >= 3 {
                samples.sort()
                return samples[samples.count / 2]
            }
        }
        return snapshot.depth(atSensor: snapshot.sensorPoint(instance.centre), minConfidence: 0)
    }

    private static func contains(_ ring: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}
