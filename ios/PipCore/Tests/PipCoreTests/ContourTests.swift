import CoreGraphics
import Foundation
import Testing
import simd
@testable import PipCore

/// How outlines are prepared for drawing (see Contour): evenly spaced, smooth, just outside the
/// object, and point for point comparable from one mask to the next.
@Suite struct ContourTests {
    static func square(_ side: Double, steps: Int) -> [SIMD2<Double>] {
        // A square traced in pixel steps, clockwise with y down.
        var pts: [SIMD2<Double>] = []
        for i in 0..<steps { pts.append(SIMD2(side * Double(i) / Double(steps), 0)) }
        for i in 0..<steps { pts.append(SIMD2(side, side * Double(i) / Double(steps))) }
        for i in 0..<steps { pts.append(SIMD2(side - side * Double(i) / Double(steps), side)) }
        for i in 0..<steps { pts.append(SIMD2(0, side - side * Double(i) / Double(steps))) }
        return pts
    }

    @Test func resamplingSpacesPointsEvenly() {
        let ring: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(30, 0), SIMD2(30, 10), SIMD2(0, 10)]
        let even = Contour.resample(ring, count: 16)
        #expect(even.count == 16)
        #expect(even[0] == SIMD2(0, 0))
        for i in 0..<16 {
            let d = Contour.length(even[(i + 1) % 16] - even[i])
            // 80 / 16 = 5 along the edge; a step round a corner is a little shorter.
            #expect(d <= 5.0001 && d > 3.5)
        }
    }

    @Test func aStaircaseIsSmoothedOntoItsEdge() {
        // A diagonal edge drawn in 1-pixel steps: smoothing brings the points onto the diagonal.
        var stairs: [SIMD2<Double>] = []
        for i in 0..<40 { stairs.append(SIMD2(Double(i), Double(i))); stairs.append(SIMD2(Double(i + 1), Double(i))) }
        // Closed back along a straight line far away, so only the middle is checked.
        stairs.append(SIMD2(40, 80)); stairs.append(SIMD2(0, 80))
        let soft = Contour.smooth(stairs, passes: 8)
        for i in 20..<60 {
            let p = soft[i]
            // Distance to the line y = x − 0.5 (the steps' middle).
            #expect(abs(p.x - p.y - 0.5) / 2.0.squareRoot() < 0.2)
        }
    }

    @Test func theOutlineSitsJustOutsideTheObject() {
        let ring = [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 40), CGPoint(x: 0, y: 40)]
        for r in [ring, Array(ring.reversed())] {
            let shown = Contour.display(r, spacing: 2, outset: 2)
            let b = Contour.bounds([shown])
            // Outside on every side, by about the outset (corners are rounded a little).
            #expect(b.minX < -1.5 && b.minX > -2.5 && b.maxX > 41.5 && b.maxX < 42.5)
            #expect(b.minY < -1.5 && b.maxY > 41.5)
            // Clockwise on screen, from the top.
            #expect(Contour.signedArea(shown) > 0)
            #expect(shown[0].y <= shown.map(\.y).min()! + 0.001)
        }
    }

    @Test func aMovedOutlineIsMatchedPointForPoint() {
        let ring = Contour.resample(Self.square(1, steps: 8).map { SIMD3<Float>(Float($0.x), Float($0.y), 2) }, count: 32)
        // The next mask: moved 2 cm, starting elsewhere on the ring, and run the other way round.
        let moved = ring.map { $0 + SIMD3<Float>(0.02, 0, 0) }
        let next = Array((moved[11...] + moved[..<11]).reversed())
        let aligned = Contour.aligned(next, to: ring, eitherWay: true)
        for i in 0..<32 { #expect(simd_distance(aligned[i], ring[i]) < 0.021) }
        // Without trying both directions, half the points would cross the outline.
        let oneWay = Contour.aligned(next, to: ring)
        #expect((0..<32).contains { simd_distance(oneWay[$0], ring[$0]) > 0.3 })
    }

    @Test func aDrawingOutlineCanStopPartWay() {
        let ring = Contour.display([CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 40), CGPoint(x: 0, y: 40)], spacing: 2)
        let half = Contour.path(ring, upTo: 0.5)
        let whole = Contour.path(ring)
        #expect(half.boundingBoxOfPath.height < whole.boundingBoxOfPath.height + 0.01)
        #expect(Contour.point(ring, at: 0) == ring[0])
        // Half way round from the top, clockwise: the bottom side.
        #expect(Contour.point(ring, at: 0.5)!.y > 40)
    }

    @Test func labelsMeetTheOutline() {
        // A bowl: its top edge dips in the middle.
        let bowl = [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 10), CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 30), CGPoint(x: 0, y: 30)]
        #expect(Contour.verticalHit(on: [bowl], x: 20, fromTop: true) == CGPoint(x: 20, y: 10))
        #expect(Contour.verticalHit(on: [bowl], x: 20, fromTop: false) == CGPoint(x: 20, y: 30))
        #expect(Contour.verticalHit(on: [bowl], x: 60, fromTop: true) == nil)
        let near = Contour.nearestPoint(on: [bowl], to: CGPoint(x: 50, y: 15))!
        #expect(abs(near.x - 40) < 0.001 && abs(near.y - 15) < 0.001)
    }

    @Test func edgeTAMOutlinesAreSmoothAndAlwaysTheSameLength() {
        let w = 100, h = 100
        var m = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w where hypot(Double(x) - 50, Double(y) - 50) < 30 { m[y * w + x] = 1 } }
        let c = EdgeTAM.contour(m, width: w, height: h)
        #expect(c.count == 96)
        // On the circle through the boundary pixels' centres (radius 29.0–30.0 about the disc's
        // centre, which is at 50.5 in pixel-centre coordinates), without their steps.
        let radii = c.map { hypot($0.x - 50.5, $0.y - 50.5) }
        #expect(radii.allSatisfy { $0 > 28.9 && $0 < 30 })
        #expect(radii.max()! - radii.min()! < 0.8)
        let steps = EdgeTAM.outline(m, width: w, height: h)
        #expect(steps.count < 96)
        // A small mask gets the same number of points.
        var tiny = [UInt8](repeating: 0, count: 20 * 20)
        for y in 8..<12 { for x in 8..<13 { tiny[y * 20 + x] = 1 } }
        #expect(EdgeTAM.contour(tiny, width: 20, height: 20).count == 96)
    }
}
