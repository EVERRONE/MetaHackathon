import CoreGraphics
import simd

/// Closed outlines as Pip draws them. A mask's edge comes in pixel steps; drawn as is, and redrawn
/// at every new mask with slightly different steps, it looks hand-drawn and wobbly. Here an outline
/// becomes evenly spaced points (the same number every time, so one outline can morph into the
/// next), is smoothed to the edge the pixels approximate, set just outside the object, and drawn as
/// one smooth curve.
public enum Contour {
    // MARK: Points along the outline (2D and 3D alike)

    public static func length<V: SIMD>(_ v: V) -> V.Scalar where V.Scalar: BinaryFloatingPoint {
        (v * v).sum().squareRoot()
    }

    public static func perimeter<V: SIMD>(_ ring: [V]) -> V.Scalar where V.Scalar: BinaryFloatingPoint {
        guard ring.count > 1 else { return 0 }
        var total: V.Scalar = 0
        for i in 0..<ring.count { total += length(ring[(i + 1) % ring.count] - ring[i]) }
        return total
    }

    public static func centroid<V: SIMD>(_ ring: [V]) -> V where V.Scalar: BinaryFloatingPoint {
        guard !ring.isEmpty else { return V() }
        return ring.reduce(V(), +) / V(repeating: V.Scalar(ring.count))
    }

    /// `count` points evenly spaced along the closed ring, starting at its first point.
    public static func resample<V: SIMD>(_ ring: [V], count: Int) -> [V] where V.Scalar: BinaryFloatingPoint {
        guard ring.count >= 2, count >= 1 else { return ring }
        let total = perimeter(ring)
        guard total > 0 else { return Array(repeating: ring[0], count: count) }
        let step = total / V.Scalar(count)
        var out: [V] = []
        out.reserveCapacity(count)
        var segment = 0
        var segmentStart: V.Scalar = 0
        var segmentLength = length(ring[1 % ring.count] - ring[0])
        for k in 0..<count {
            let s = V.Scalar(k) * step
            while segmentStart + segmentLength < s, segment < ring.count - 1 {
                segmentStart += segmentLength
                segment += 1
                segmentLength = length(ring[(segment + 1) % ring.count] - ring[segment])
            }
            let a = ring[segment], b = ring[(segment + 1) % ring.count]
            let t = segmentLength > 0 ? min(max((s - segmentStart) / segmentLength, 0), 1) : 0
            out.append(a + (b - a) * V(repeating: t))
        }
        return out
    }

    /// Binomial smoothing round the ring: each pass is [1 2 1] / 4, `passes` passes act like a
    /// Gaussian of variance passes / 2 (in point spacings).
    public static func smooth<V: SIMD>(_ ring: [V], passes: Int) -> [V] where V.Scalar: BinaryFloatingPoint {
        let n = ring.count
        guard n >= 3, passes > 0 else { return ring }
        var cur = ring
        var next = ring
        let quarter = V(repeating: 0.25), half = V(repeating: 0.5)
        for _ in 0..<passes {
            for i in 0..<n {
                next[i] = cur[(i + n - 1) % n] * quarter + cur[i] * half + cur[(i + 1) % n] * quarter
            }
            swap(&cur, &next)
        }
        return cur
    }

    /// The same ring started at the point that makes it lie closest to `reference` (same count):
    /// so point i of one outline morphs into point i of the next. `eitherWay`: also tries the ring
    /// run the other way round (outlines from different sources need not agree on the direction).
    public static func aligned<V: SIMD>(_ ring: [V], to reference: [V], eitherWay: Bool = false) -> [V] where V.Scalar: BinaryFloatingPoint {
        let n = ring.count
        guard n == reference.count, n > 1 else { return ring }
        func best(_ r: [V]) -> (shift: Int, cost: V.Scalar) {
            var best = 0
            var bestCost = V.Scalar.infinity
            for shift in 0..<n {
                var cost: V.Scalar = 0
                for i in 0..<n {
                    let d = r[(i + shift) % n] - reference[i]
                    cost += (d * d).sum()
                    if cost >= bestCost { break }
                }
                if cost < bestCost { bestCost = cost; best = shift }
            }
            return (best, bestCost)
        }
        var r = ring
        var b = best(r)
        if eitherWay {
            let reversed = Array(ring.reversed())
            let rb = best(reversed)
            if rb.cost < b.cost { r = reversed; b = rb }
        }
        return Array(r[b.shift...] + r[..<b.shift])
    }

    // MARK: On screen

    /// Shoelace area; positive when the ring runs clockwise on a screen (y down).
    public static func signedArea(_ ring: [CGPoint]) -> CGFloat {
        guard ring.count >= 3 else { return 0 }
        var a: CGFloat = 0
        for i in 0..<ring.count {
            let p = ring[i], q = ring[(i + 1) % ring.count]
            a += p.x * q.y - q.x * p.y
        }
        return a / 2
    }

    /// Each point moved `distance` along the outward normal.
    public static func offset(_ ring: [CGPoint], by distance: CGFloat) -> [CGPoint] {
        let n = ring.count
        guard n >= 3, distance != 0 else { return ring }
        let sign: CGFloat = signedArea(ring) >= 0 ? 1 : -1
        return (0..<n).map { i in
            let t = CGPoint(x: ring[(i + 1) % n].x - ring[(i + n - 1) % n].x, y: ring[(i + 1) % n].y - ring[(i + n - 1) % n].y)
            let len = hypot(t.x, t.y)
            guard len > 1e-9 else { return ring[i] }
            return CGPoint(x: ring[i].x + sign * t.y / len * distance, y: ring[i].y - sign * t.x / len * distance)
        }
    }

    /// Clockwise on screen, starting at the topmost point: every outline draws on the same way.
    public static func startingAtTop(_ ring: [CGPoint]) -> [CGPoint] {
        guard ring.count >= 3 else { return ring }
        let cw = signedArea(ring) >= 0 ? ring : ring.reversed()
        guard let top = cw.indices.min(by: { cw[$0].y < cw[$1].y }) else { return cw }
        return Array(cw[top...] + cw[..<top])
    }

    /// An outline ready to draw: evenly spaced about every `spacing` points, smoothed, `outset`
    /// outside the object's edge, clockwise from the top.
    public static func display(_ ring: [CGPoint], spacing: CGFloat = 3, outset: CGFloat = 1.5) -> [CGPoint] {
        guard ring.count >= 3 else { return ring }
        let per = perimeter(ring.map { SIMD2<Double>(Double($0.x), Double($0.y)) })
        let count = min(240, max(16, Int((per / Double(spacing)).rounded())))
        let even = resample(ring.map { SIMD2<Double>(Double($0.x), Double($0.y)) }, count: count)
        let soft = smooth(even, passes: 2).map { CGPoint(x: $0.x, y: $0.y) }
        return startingAtTop(offset(soft, by: outset))
    }

    /// A smooth curve through the points (Catmull-Rom as cubic Béziers). `upTo` < 1 draws only
    /// that fraction of the closed ring, open, for an outline that draws itself on.
    public static func path(_ ring: [CGPoint], upTo fraction: CGFloat = 1) -> CGPath {
        let path = CGMutablePath()
        let n = ring.count
        guard n >= 3 else {
            if let first = ring.first { path.move(to: first); ring.dropFirst().forEach { path.addLine(to: $0) } }
            return path
        }
        func p(_ i: Int) -> CGPoint { ring[((i % n) + n) % n] }
        func segment(_ i: Int) {
            let p0 = p(i - 1), p1 = p(i), p2 = p(i + 1), p3 = p(i + 2)
            path.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        path.move(to: ring[0])
        if fraction >= 1 {
            for i in 0..<n { segment(i) }
            path.closeSubpath()
            return path
        }
        let f = max(0, fraction) * CGFloat(n)
        let whole = Int(f)
        for i in 0..<whole { segment(i) }
        // The last, partial segment as a straight piece: it is under a point's spacing long.
        let rest = f - CGFloat(whole)
        if rest > 0 {
            let a = p(whole), b = p(whole + 1)
            path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * rest, y: a.y + (b.y - a.y) * rest))
        }
        return path
    }

    /// The point `fraction` of the way round the ring (for the head of an outline drawing on).
    public static func point(_ ring: [CGPoint], at fraction: CGFloat) -> CGPoint? {
        guard !ring.isEmpty else { return nil }
        let f = min(max(0, fraction), 1) * CGFloat(ring.count)
        let i = Int(f) % ring.count
        let a = ring[i], b = ring[(i + 1) % ring.count], t = f - CGFloat(Int(f))
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Where the vertical line at `x` first meets the rings' edges, from the top (or from the
    /// bottom): a label straight above an object has its leader line go straight down to it.
    public static func verticalHit(on rings: [[CGPoint]], x: CGFloat, fromTop: Bool) -> CGPoint? {
        var best: CGFloat?
        for ring in rings where ring.count >= 2 {
            for i in 0..<ring.count {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                guard (a.x <= x && b.x >= x) || (b.x <= x && a.x >= x) else { continue }
                let y = abs(b.x - a.x) < 1e-9 ? (fromTop ? min(a.y, b.y) : max(a.y, b.y)) : a.y + (x - a.x) / (b.x - a.x) * (b.y - a.y)
                if let cur = best { best = fromTop ? min(cur, y) : max(cur, y) } else { best = y }
            }
        }
        return best.map { CGPoint(x: x, y: $0) }
    }

    /// The point on the rings' edges nearest to `p` (for a label's leader line to meet the outline).
    public static func nearestPoint(on rings: [[CGPoint]], to p: CGPoint) -> CGPoint? {
        var best: CGPoint?
        var bestDistance = CGFloat.infinity
        for ring in rings where !ring.isEmpty {
            for i in 0..<ring.count {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                let dx = b.x - a.x, dy = b.y - a.y
                let len2 = dx * dx + dy * dy
                let t = len2 > 0 ? min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1) : 0
                let q = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
                let d = hypot(q.x - p.x, q.y - p.y)
                if d < bestDistance { bestDistance = d; best = q }
            }
        }
        return best
    }

    public static func bounds(_ rings: [[CGPoint]]) -> CGRect {
        let pts = rings.flatMap { $0 }
        guard let first = pts.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
