import CoreGraphics
import Foundation

/// Geometry helpers for matching points to SAM instances.
enum Grounding {
    /// Whether the point lies inside one of the instance's outlines.
    static func contains(_ inst: SegmentInstance, _ p: CGPoint) -> Bool {
        guard inst.boxRect.insetBy(dx: -1, dy: -1).contains(p) else { return false }
        return inst.outlinePoints.contains { ring in
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

    /// Distance from a point to a rectangle (0 inside).
    static func distance(_ p: CGPoint, _ r: CGRect) -> Double {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return Double(hypot(dx, dy))
    }
}

extension SegmentInstance {
    /// The same instance with a new mark number.
    public func renumbered(_ id: Int) -> SegmentInstance {
        var c = self
        c.id = id
        c.contains = nil
        return c
    }

    /// Geometry mapped into a crop: subtract the crop origin, then scale.
    public func mapped(into crop: CGRect, scale: CGFloat) -> SegmentInstance {
        func mx(_ x: Int) -> Int { Int(((CGFloat(x) - crop.minX) * scale).rounded()) }
        func my(_ y: Int) -> Int { Int(((CGFloat(y) - crop.minY) * scale).rounded()) }
        var c = self
        c.box = [mx(box[0]), my(box[1]), mx(box[2]), my(box[3])]
        c.centroid = [mx(centroid[0]), my(centroid[1])]
        c.polygons = polygons.map { flat in
            stride(from: 0, to: flat.count - 1, by: 2).flatMap { [mx(flat[$0]), my(flat[$0 + 1])] }
        }
        return c
    }

    /// Geometry from an enlarged crop back to the frame: divide by the scale, then add the crop origin.
    public func unmapped(from crop: CGRect, scale: CGFloat) -> SegmentInstance {
        func mx(_ x: Int) -> Int { Int((CGFloat(x) / scale + crop.minX).rounded()) }
        func my(_ y: Int) -> Int { Int((CGFloat(y) / scale + crop.minY).rounded()) }
        var c = self
        c.box = [mx(box[0]), my(box[1]), mx(box[2]), my(box[3])]
        c.centroid = [mx(centroid[0]), my(centroid[1])]
        c.area = Int((CGFloat(area) / (scale * scale)).rounded())
        c.polygons = polygons.map { flat in
            stride(from: 0, to: flat.count - 1, by: 2).flatMap { [mx(flat[$0]), my(flat[$0 + 1])] }
        }
        return c
    }
}
