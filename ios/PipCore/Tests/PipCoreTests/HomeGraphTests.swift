import Foundation
import Testing
import simd
@testable import PipCore

@Suite struct HomeGraphTests {
    // Four sessions of one home, each in coordinates of its own (the truth: where each session's
    // origin sits in the home, as a turn and a shift).
    static let s1 = UUID(), s2 = UUID(), s3 = UUID(), s4 = UUID()
    static let home: [UUID: UprightTransform] = [
        s1: UprightTransform(yaw: 0.3, t: SIMD3(1, 0, 2)),
        s2: UprightTransform(yaw: -1.2, t: SIMD3(-2, 0.1, 0.5)),
        s3: UprightTransform(yaw: 2.0, t: SIMD3(0.4, -0.2, -3)),
        s4: UprightTransform(yaw: 0.9, t: SIMD3(5, 0, 1)),
    ]
    /// The true link carrying points of `a` into `b`: into the home, then out of it.
    static func truth(_ a: UUID, _ b: UUID) -> UprightTransform { home[a]!.then(home[b]!.inverse) }
    static func edge(_ a: UUID, _ b: UUID, matches: Int = 300, error: SIMD3<Float> = .zero) -> HomeGraph.Edge {
        var t = truth(a, b)
        t.t += error
        return HomeGraph.Edge(from: a, to: b, transform: t, matches: matches, views: 3, centre: .zero)
    }

    @Test func aThingIsCarriedThroughSessionsThatNeverSawItsPlace() throws {
        // The statues' session (1) linked to the walk to the dining room (2), which linked to the
        // dining room's session (3): 1 and 3 never saw the same place.
        var graph = HomeGraph()
        #expect(graph.add(Self.edge(Self.s1, Self.s2)) == .joined)
        #expect(graph.add(Self.edge(Self.s3, Self.s2)) == .joined)
        #expect(graph.component(of: Self.s3) == [Self.s1, Self.s2, Self.s3])
        let statues = SIMD3<Float>(0.4, -0.3, -1.2)
        let carried = try #require(graph.transform(from: Self.s1, to: Self.s3)).apply(statues)
        #expect(simd_distance(carried, Self.truth(Self.s1, Self.s3).apply(statues)) < 1e-4)
        // A session not joined to them: no way there.
        #expect(graph.transform(from: Self.s1, to: Self.s4) == nil)
    }

    @Test func theStrongestChainCarries() throws {
        var graph = HomeGraph()
        // A weak direct link 3 cm off, and a strong chain through 2: the chain carries.
        graph.add(Self.edge(Self.s1, Self.s2, matches: 800))
        graph.add(Self.edge(Self.s2, Self.s3, matches: 700))
        graph.add(Self.edge(Self.s1, Self.s3, matches: 90, error: SIMD3(0.03, 0, 0)))
        let p = SIMD3<Float>(0, 0, 0)
        let carried = try #require(graph.transform(from: Self.s1, to: Self.s3)).apply(p)
        #expect(simd_distance(carried, Self.truth(Self.s1, Self.s3).apply(p)) < 1e-4)
    }

    @Test func aLinkThatBreaksALoopIsRefused() {
        var graph = HomeGraph()
        graph.add(Self.edge(Self.s1, Self.s2))
        graph.add(Self.edge(Self.s2, Self.s3))
        // A look-alike place: 1 and 3 "linked" 1.5 m off what the chain through 2 says.
        if case .refused(let apart) = graph.add(Self.edge(Self.s1, Self.s3, error: SIMD3(1.5, 0, 0))) {
            #expect(apart > 1.4)
        } else {
            Issue.record("a loop 1.5 m apart was taken")
        }
        // One within drift (5 cm) closes the loop.
        #expect(graph.add(Self.edge(Self.s1, Self.s3, error: SIMD3(0.05, 0, 0))) == .joined)
    }

    @Test func aStrongerLinkReplacesAWeakerOneForThePair() {
        var graph = HomeGraph()
        graph.add(Self.edge(Self.s1, Self.s2, matches: 100))
        #expect(graph.add(Self.edge(Self.s2, Self.s1, matches: 90)) == .weaker)
        #expect(graph.add(Self.edge(Self.s2, Self.s1, matches: 400)) == .replaced)
        #expect(graph.edges.count == 1)
    }

    @Test func aLinkMadeAfreshReplacesTheOldOneWhateverItsStrength() throws {
        var graph = HomeGraph()
        graph.add(Self.edge(Self.s1, Self.s2, matches: 900))
        // The live session's coordinates moved 20 cm at a tracking break; its new link is weaker.
        graph.removeLink(between: Self.s1, and: Self.s2)
        #expect(graph.add(Self.edge(Self.s1, Self.s2, matches: 200, error: SIMD3(0.2, 0, 0))) == .joined)
        let moved = try #require(graph.transform(from: Self.s1, to: Self.s2)).apply(.zero)
        #expect(simd_distance(moved, Self.truth(Self.s1, Self.s2).apply(.zero) + SIMD3(0.2, 0, 0)) < 1e-4)
    }

    @Test func aTrackingBreakThatMovedTheLiveSessionDropsItsOlderLinks() throws {
        // 1 and 2 linked to the live session (4) before its tracking broke, and to each other.
        let before = Date(timeIntervalSince1970: 1000), broke = Date(timeIntervalSince1970: 2000)
        var graph = HomeGraph()
        for (a, b) in [(Self.s1, Self.s4), (Self.s2, Self.s4), (Self.s1, Self.s2)] {
            var e = Self.edge(a, b)
            e.made = before
            graph.add(e)
        }
        // The link of a pair, either way round.
        let back = try #require(graph.link(from: Self.s4, to: Self.s1))
        #expect(simd_distance(back.transform.apply(.zero), Self.truth(Self.s4, Self.s1).apply(.zero)) < 1e-4)
        // The break moved the live session 30 cm: 1's fresh link shows it; the old links of 4 go,
        // the one between 1 and 2 stays, and the fresh link joins without a stale loop refusing it.
        graph.removeLinks(of: Self.s4, madeBefore: broke)
        #expect(graph.edges.count == 1)
        var fresh = Self.edge(Self.s1, Self.s4, error: SIMD3(0.3, 0, 0))
        fresh.made = broke.addingTimeInterval(5)
        #expect(graph.add(fresh) == .joined)
        #expect(graph.component(of: Self.s4) == [Self.s1, Self.s2, Self.s4])
    }

    @Test func theGraphIsStoredAndReadBack() throws {
        var graph = HomeGraph()
        graph.add(Self.edge(Self.s1, Self.s2))
        let back = try JSONDecoder().decode(HomeGraph.self, from: JSONEncoder().encode(graph))
        #expect(back == graph)
    }
}
