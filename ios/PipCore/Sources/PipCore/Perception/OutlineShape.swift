import CoreGraphics
import Foundation

/// Cleans up a SAM outline for drawing. Masks follow the object closely, but their pixel steps and
/// small bumps look hand-drawn once stroked on screen. Objects that are close to a rectangle (keys,
/// breakers, buttons, labels) become an exact rotated rectangle with rounded corners; other convex
/// shapes become their smoothed hull; concave ones are only smoothed.
public enum OutlineShape {
    /// Above this, the outline fills its minimum-area rectangle well enough to be drawn as one.
    static let rectangularity: CGFloat = 0.85
    /// Above this, the outline fills its convex hull well enough to be drawn as the hull.
    static let solidity: CGFloat = 0.92

    public static func regularize(_ ring: [CGPoint]) -> [CGPoint] {
        guard ring.count >= 4 else { return ring }
        let area = abs(signedArea(ring))
        let hull = convexHull(ring)
        guard hull.count >= 3, area > 0 else { return ring }
        if let rect = minAreaRect(hull), area / (rect.width * rect.height) >= rectangularity {
            return roundedRect(rect, radius: min(rect.width, rect.height) * 0.18)
        }
        if area / abs(signedArea(hull)) >= solidity {
            return chaikin(hull, iterations: 2)
        }
        return chaikin(ring, iterations: 1)
    }

    // MARK: Geometry

    public struct OrientedRect: Equatable {
        public var center: CGPoint
        public var width: CGFloat
        public var height: CGFloat
        /// Rotation of the width axis, in radians.
        public var angle: CGFloat
    }

    static func signedArea(_ ring: [CGPoint]) -> CGFloat {
        var a: CGFloat = 0
        for i in 0..<ring.count {
            let p = ring[i], q = ring[(i + 1) % ring.count]
            a += p.x * q.y - q.x * p.y
        }
        return a / 2
    }

    /// Andrew's monotone chain, counter-clockwise.
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let pts = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard pts.count >= 3 else { return pts }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = []
        for p in pts {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in pts.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// The smallest rectangle around a convex hull: one of its sides lies on a hull edge.
    static func minAreaRect(_ hull: [CGPoint]) -> OrientedRect? {
        var best: OrientedRect?
        var bestArea = CGFloat.infinity
        for i in 0..<hull.count {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len > 1e-6 else { continue }
            let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
            var minU = CGFloat.infinity, maxU = -CGFloat.infinity, minV = CGFloat.infinity, maxV = -CGFloat.infinity
            for p in hull {
                let u = p.x * ux + p.y * uy
                let v = -p.x * uy + p.y * ux
                minU = min(minU, u); maxU = max(maxU, u); minV = min(minV, v); maxV = max(maxV, v)
            }
            let area = (maxU - minU) * (maxV - minV)
            if area < bestArea {
                bestArea = area
                let cu = (minU + maxU) / 2, cv = (minV + maxV) / 2
                best = OrientedRect(center: CGPoint(x: cu * ux - cv * uy, y: cu * uy + cv * ux),
                                    width: maxU - minU, height: maxV - minV, angle: atan2(uy, ux))
            }
        }
        return best
    }

    static func roundedRect(_ r: OrientedRect, radius: CGFloat, segments: Int = 5) -> [CGPoint] {
        let hw = r.width / 2, hh = r.height / 2
        let rad = min(radius, hw, hh)
        // Corner centres, counter-clockwise, with the start angle of each quarter arc.
        let corners: [(CGFloat, CGFloat, CGFloat)] = [
            (hw - rad, -hh + rad, -.pi / 2), (hw - rad, hh - rad, 0),
            (-hw + rad, hh - rad, .pi / 2), (-hw + rad, -hh + rad, .pi),
        ]
        let c = cos(r.angle), s = sin(r.angle)
        var out: [CGPoint] = []
        for (cx, cy, start) in corners {
            for k in 0...segments {
                let t = start + CGFloat(k) / CGFloat(segments) * .pi / 2
                let x = cx + rad * cos(t), y = cy + rad * sin(t)
                out.append(CGPoint(x: r.center.x + x * c - y * s, y: r.center.y + x * s + y * c))
            }
        }
        return out
    }

    /// Chaikin corner cutting: each pass replaces every edge by its ¼ and ¾ points.
    static func chaikin(_ ring: [CGPoint], iterations: Int) -> [CGPoint] {
        var pts = ring
        for _ in 0..<iterations {
            var next: [CGPoint] = []
            next.reserveCapacity(pts.count * 2)
            for i in 0..<pts.count {
                let p = pts[i], q = pts[(i + 1) % pts.count]
                next.append(CGPoint(x: 0.75 * p.x + 0.25 * q.x, y: 0.75 * p.y + 0.25 * q.y))
                next.append(CGPoint(x: 0.25 * p.x + 0.75 * q.x, y: 0.25 * p.y + 0.75 * q.y))
            }
            pts = next
        }
        return pts
    }
}

extension SegmentInstance {
    /// The same instance with outlines cleaned up for drawing (see `OutlineShape`).
    public func regularized() -> SegmentInstance {
        var c = self
        c.polygons = outlinePoints.map { ring in
            OutlineShape.regularize(ring).flatMap { [Int($0.x.rounded()), Int($0.y.rounded())] }
        }
        return c
    }
}
