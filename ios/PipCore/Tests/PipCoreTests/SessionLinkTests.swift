import Testing
import simd
@testable import PipCore

@Suite struct SessionLinkTests {
    static let truth = UprightTransform(yaw: 0.6, t: SIMD3(1.2, -0.15, -0.8))

    @Test func anUprightTransformIsFittedUndoneAndChained() {
        var rng = SplitMix64(seed: 3)
        func r() -> Float { Float(rng.next() % 2000) / 1000 - 1 }
        let a = (0..<20).map { _ in SIMD3(r(), r(), r()) }
        let b = a.map { Self.truth.apply($0) }
        let fit = UprightTransform.fit(a, b)
        #expect(abs(fit.yaw - Self.truth.yaw) < 1e-4)
        #expect(simd_distance(fit.t, Self.truth.t) < 1e-4)
        let p = SIMD3<Float>(0.3, 0.2, -0.4)
        #expect(simd_distance(Self.truth.inverse.apply(Self.truth.apply(p)), p) < 1e-5)
        let other = UprightTransform(yaw: -0.2, t: SIMD3(0, 0.1, 0.3))
        #expect(simd_distance(Self.truth.then(other).apply(p), other.apply(Self.truth.apply(p))) < 1e-5)
        let q = Self.truth.matrix * SIMD4(p, 1)
        #expect(simd_distance(SIMD3(q.x, q.y, q.z), Self.truth.apply(p)) < 1e-5)
    }

    /// Two snapshots of one scene from two sessions: 120 described points seen in both (5 mm of
    /// depth noise, a few flipped bits), 60 seen only in one, and 40 matches lifted to the wrong
    /// depth (a depth edge).
    static func views(_ t: UprightTransform, seed: UInt64, centre: SIMD3<Float> = .zero, size: Float = 1) -> (ViewPoints, ViewPoints) {
        var rng = SplitMix64(seed: seed)
        func r() -> Float { Float(rng.next() % 2000) / 1000 - 1 }
        func bits() -> (UInt64, UInt64, UInt64, UInt64) { (rng.next(), rng.next(), rng.next(), rng.next()) }
        func flip(_ b: (UInt64, UInt64, UInt64, UInt64)) -> (UInt64, UInt64, UInt64, UInt64) {
            (b.0 ^ (1 << (rng.next() % 64)) ^ (1 << (rng.next() % 64)), b.1 ^ (1 << (rng.next() % 64)), b.2, b.3 ^ (1 << (rng.next() % 64)))
        }
        var fa: [FeatureMatcher.Feature] = [], wa: [SIMD3<Float>?] = []
        var fb: [FeatureMatcher.Feature] = [], wb: [SIMD3<Float>?] = []
        for k in 0..<220 {
            let p = centre + SIMD3(r() * 0.8, r() * 0.4, r() * 0.8) * size
            let d = bits()
            let pixel = SIMD2<Float>(Float(k), Float(k))
            if k < 160 {
                fa.append(FeatureMatcher.Feature(point: pixel, bits: d)); wa.append(p)
                let noise = SIMD3(r(), r(), r()) * 0.005
                let q = k < 120 ? t.apply(p) + noise : t.apply(p) + SIMD3(0, 0, 0.3 + r() * 0.2)
                fb.append(FeatureMatcher.Feature(point: pixel, bits: flip(d))); wb.append(q)
            } else if k < 190 {
                fa.append(FeatureMatcher.Feature(point: pixel, bits: d)); wa.append(p)
            } else {
                fb.append(FeatureMatcher.Feature(point: pixel, bits: d)); wb.append(t.apply(p))
            }
        }
        return (ViewPoints(features: fa, world: wa), ViewPoints(features: fb, world: wb))
    }

    @Test func twoViewsOfTheSameThingsGiveTheLink() throws {
        let (a, b) = Self.views(Self.truth, seed: 11)
        let link = try #require(SessionLink.link(a, b))
        #expect(link.inliers >= 100)
        #expect(abs(link.transform.yaw - Self.truth.yaw) < 0.01)
        #expect(simd_distance(link.transform.t, Self.truth.t) < 0.01)
        #expect(link.residual < 0.01)
    }

    @Test func agreeingViewsMakeASessionLinkAndALookAlikeDoesNot() throws {
        let (a1, b1) = Self.views(Self.truth, seed: 21)
        let (a2, b2) = Self.views(Self.truth, seed: 22, centre: SIMD3(1, 0, 0.5))
        // A look-alike place elsewhere: a confident fit, but another turn and shift.
        let wrong = UprightTransform(yaw: -0.4, t: SIMD3(-2, 0, 1))
        let (a3, b3) = Self.views(wrong, seed: 23)
        var l1 = try #require(SessionLink.link(a1, b1, from: 1, to: 1))
        let l2 = try #require(SessionLink.link(a2, b2, from: 2, to: 2))
        let l3 = try #require(SessionLink.link(a3, b3, from: 3, to: 3))
        #expect(SessionLink.agree(l1, l2))
        #expect(!SessionLink.agree(l1, l3))
        let group = try #require(SessionLink.consensus([l1, l2, l3]))
        #expect(Set(group.map(\.to)) == [1, 2])
        // One view alone is not enough.
        #expect(SessionLink.consensus([l1]) == nil)
        // Two links from the same snapshot on the second side are one view.
        l1.to = 2
        #expect(SessionLink.consensus([l1, l2]) == nil)
    }

    @Test func whatIsHeldNearTheCameraDoesNotLinkRooms() throws {
        // A laptop-sized scene (about 30 cm) seen from 45 cm: every point within 0.8 m of both cameras.
        let (a0, b0) = Self.views(Self.truth, seed: 31, size: 0.2)
        var a = a0, b = b0
        a.camera = SIMD3(0, 0, 0.45)
        b.camera = Self.truth.apply(SIMD3(0, 0, 0.45))
        #expect(SessionLink.link(a, b) == nil)
        // A room-sized scene seen from 2.5 m links.
        let (c0, d0) = Self.views(Self.truth, seed: 31)
        var c = c0, d = d0
        c.camera = SIMD3(0, 0, 2.5)
        d.camera = Self.truth.apply(SIMD3(0, 0, 2.5))
        #expect(SessionLink.link(c, d) != nil)
    }

    @Test func evidenceInOneSpotIsNotASessionLink() throws {
        // Two agreeing views of one small thing (a moved object): too little of the room.
        let small = ViewLink(transform: Self.truth, inliers: 100, residual: 0.005, centre: .zero, spread: 0.1, from: 1, to: 1)
        var other = small
        other.centre = SIMD3(0.1, 0, 0)
        other.to = 2
        #expect(SessionLink.consensus([small, other]) == nil)
        // The same, a metre and a half apart: the room.
        other.centre = SIMD3(1.5, 0, 0)
        #expect(SessionLink.consensus([small, other]) != nil)
    }

    @Test func aPointIsCarriedByTheLinksNearIt() throws {
        // Each session drifts: near the first evidence the link is the truth, near the second it is
        // 3 cm off. A point at the first evidence goes by the first.
        let near = ViewLink(transform: Self.truth, inliers: 100, residual: 0.005, centre: .zero, spread: 0.3, from: 1, to: 1)
        var shifted = Self.truth
        shifted.t += SIMD3(0.03, 0, 0)
        let far = ViewLink(transform: shifted, inliers: 100, residual: 0.005, centre: SIMD3(3, 0, 0), spread: 0.3, from: 2, to: 2)
        let p = SIMD3<Float>(0.1, 0, 0)
        let carried = try #require(SessionLink.carry(p, by: [near, far]))
        #expect(simd_distance(carried, Self.truth.apply(p)) < 0.005)
    }
}
