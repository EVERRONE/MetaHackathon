import CoreGraphics
import Foundation
import Testing
import simd
@testable import PipCore

@Suite struct LinkBookTests {
    static let earlier = UUID()
    static let truth = UprightTransform(yaw: 0.5, t: SIMD3(1, -0.2, 0.4))

    /// A view link of stored view `from` with live view `to`, its evidence at `centre`.
    static func link(_ t: UprightTransform, from: Int, to: Int, centre: SIMD3<Float>, inliers: Int = 60) -> ViewLink {
        ViewLink(transform: t, inliers: inliers, residual: 0.006, centre: centre, spread: 0.3, from: from, to: to)
    }

    /// Where `book` carries a point of the earlier session: by the link nearest it, as the app
    /// carries poses and anchors.
    static func carried(_ p: SIMD3<Float>, by book: LinkBook) -> SIMD3<Float>? {
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4(p, 1)
        return book.carry(pose: pose, of: earlier, near: p).map { simd_make_float3($0.columns.3) }
    }

    @Test func depthIsTrustedOnlyOffEdges() {
        #expect(TrustedDepth.of([1.20, 1.21, 1.22, 1.20, 1.23]) == 1.21)
        // Across a depth edge (a table edge in front of the floor).
        #expect(TrustedDepth.of([1.20, 1.21, 1.95, 1.96, 1.22]) == nil)
        // Too few samples within range (no LiDAR return, or beyond 6 m).
        #expect(TrustedDepth.of([1.2, 1.21, 0, 7, 1.22]) == nil)
    }

    @Test func aSessionIsLinkedByTwoLiveViewsThatAgree() throws {
        var book = LinkBook()
        // One live view alone: not yet.
        #expect(book.add([(Self.earlier, Self.link(Self.truth, from: 3, to: 1, centre: .zero))]).isEmpty)
        // A second live view, evidence 1.5 m away, the same turn and shift: linked.
        let changes = book.add([(Self.earlier, Self.link(Self.truth, from: 7, to: 2, centre: SIMD3(1.5, 0, 0)))])
        #expect(changes[Self.earlier] == .linked)
        let p = SIMD3<Float>(0.7, 0.1, -0.3)
        let carried = try #require(Self.carried(p, by: book))
        #expect(simd_distance(carried, Self.truth.apply(p)) < 0.001)
        // More of the same: strengthened.
        #expect(book.add([(Self.earlier, Self.link(Self.truth, from: 8, to: 3, centre: SIMD3(0.5, 0, 1)))])[Self.earlier] == .strengthened)
    }

    @Test func afterATrackingBreakTheLinkStaysUntilNewEvidenceReplacesIt() throws {
        var book = LinkBook()
        _ = book.add([(Self.earlier, Self.link(Self.truth, from: 3, to: 1, centre: .zero))])
        _ = book.add([(Self.earlier, Self.link(Self.truth, from: 7, to: 2, centre: SIMD3(1.5, 0, 0)))])
        book.trackingBroke()
        // Still carried by the link in use.
        let p = SIMD3<Float>(0.2, 0, 0.2)
        #expect(Self.carried(p, by: book).map { simd_distance($0, Self.truth.apply(p)) < 0.001 } == true)
        // The live coordinates moved by 30 cm: one new view is not enough to replace the link...
        var moved = Self.truth
        moved.t += SIMD3(0.3, 0, 0)
        #expect(book.add([(Self.earlier, Self.link(moved, from: 3, to: 3, centre: .zero))]).isEmpty)
        #expect(Self.carried(p, by: book).map { simd_distance($0, Self.truth.apply(p)) < 0.001 } == true)
        // ...two agreeing ones are, and evidence from before the break does not outvote them.
        #expect(book.add([(Self.earlier, Self.link(moved, from: 7, to: 4, centre: SIMD3(1.5, 0, 0)))])[Self.earlier] == .relinked)
        #expect(Self.carried(p, by: book).map { simd_distance($0, moved.apply(p)) < 0.001 } == true)
    }

    @Test func aViewIsCarriedByItsOwnLinkFirst() throws {
        var book = LinkBook()
        // Each session drifts: near view 3 the link is the truth, near view 7 it is 4 cm off.
        var drifted = Self.truth
        drifted.t += SIMD3(0.04, 0, 0)
        _ = book.add([(Self.earlier, Self.link(Self.truth, from: 3, to: 1, centre: .zero))])
        _ = book.add([(Self.earlier, Self.link(drifted, from: 7, to: 2, centre: SIMD3(1.5, 0, 0)))])
        // View 7 looks at the first evidence but is carried by its own link.
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4(0, 0, 1, 1)
        let carried = try #require(book.carry(pose: pose, of: Self.earlier, view: 7, near: LinkBook.lookedAt(pose)))
        #expect(simd_distance(simd_make_float3(carried.columns.3), drifted.apply(SIMD3(0, 0, 1))) < 0.001)
        // A view without a link of its own goes by the evidence nearest what it looks at.
        let other = try #require(book.carry(pose: pose, of: Self.earlier, view: 12, near: LinkBook.lookedAt(pose)))
        #expect(simd_distance(simd_make_float3(other.columns.3), Self.truth.apply(SIMD3(0, 0, 1))) < 0.001)
    }

    @Test func lookAlikesComeBeforeHotViews() {
        var schedule = LinkSchedule()
        let next = schedule.next(ready: Array(0..<30), lookAlike: [17, 4], hot: [4, 9], count: 5)
        #expect(next == [17, 4, 9, 0, 1])
    }

    @Test func aFingerprintTellsTheSameViewFromAnother() throws {
        // A textured image, the same shifted by two pixels, and a different one.
        func image(seed: UInt64, shift: Int = 0) -> CGImage {
            var rng = SplitMix64(seed: seed)
            var pixels = [UInt8](repeating: 0, count: 128 * 128)
            for _ in 0..<60 {
                let x = Int(rng.next() % 110), y = Int(rng.next() % 110), v = UInt8(rng.next() % 256)
                for dy in 0..<14 { for dx in 0..<14 where x + dx + shift < 128 { pixels[(y + dy) * 128 + x + dx + shift] = v } }
            }
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            return CGImage(width: 128, height: 128, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceGray(),
                           bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        let a = try #require(ViewPrint(image(seed: 1))), same = try #require(ViewPrint(image(seed: 1, shift: 2))), other = try #require(ViewPrint(image(seed: 2)))
        #expect(a.distance(to: same) < a.distance(to: other))
        #expect(a.nearest(1, among: [7: other, 3: same]) == [3])
    }

    @Test func hotViewsAndTheirNeighboursComeFirstThenEveryViewInTurn() {
        var book = LinkBook()
        _ = book.add([(Self.earlier, Self.link(Self.truth, from: 10, to: 1, centre: .zero))])
        let hot = book.hot(limit: 5) { [$0 - 1, $0 + 1] }
        #expect(hot == [10, 9, 11])
        var schedule = LinkSchedule()
        let ready = Array(0..<20)
        let first = schedule.next(ready: ready, hot: hot, count: 6)
        #expect(Array(first.prefix(3)) == [10, 9, 11])
        #expect(first.count == 6)
        // Every ready view comes round within a few batches.
        var seen = Set(first)
        for _ in 0..<5 { seen.formUnion(schedule.next(ready: ready, hot: [], count: 6)) }
        #expect(seen == Set(ready))
    }
}
