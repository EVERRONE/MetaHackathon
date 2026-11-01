import Foundation
import simd

/// The home as one set of coordinates (docs/spatial-memory.md): sessions joined by the links found
/// between them. A remembered thing keeps the coordinates of the session that saw it; through the
/// graph it can be carried into any session joined to that one, also one that never saw the same
/// place (the session that saw the statues, the one that walked from them to the dining room, and a
/// later one that starts in the dining room).
///
/// Each pair of sessions keeps its strongest link (most agreeing matches). Between two sessions the
/// graph carries along the strongest chain: the path in a spanning tree built strongest link first.
/// A new link that closes a loop is checked against the chain it bypasses; one that disagrees by
/// more than a session's drift is refused (a wrong link would carry every thing of every session
/// behind it).
public struct HomeGraph: Codable, Sendable, Equatable {
    public struct Edge: Codable, Sendable, Equatable {
        /// Points of `from` are carried into `to` by `transform`.
        public var from: UUID
        public var to: UUID
        public var transform: UprightTransform
        /// Agreeing matches and live views behind it, and where its evidence is (in `from`'s coordinates).
        public var matches: Int
        public var views: Int
        public var centre: SIMD3<Float>
        public var made: Date

        public init(from: UUID, to: UUID, transform: UprightTransform, matches: Int, views: Int, centre: SIMD3<Float>, made: Date = Date()) {
            self.from = from
            self.to = to
            self.transform = transform
            self.matches = matches
            self.views = views
            self.centre = centre
            self.made = made
        }

        /// The same link the other way round.
        public var reversed: Edge {
            Edge(from: to, to: from, transform: transform.inverse, matches: matches, views: views, centre: transform.apply(centre), made: made)
        }
    }

    public private(set) var edges: [Edge] = []

    /// A loop may disagree by this much at its evidence: two sessions' drift (1 Nov: a loop through
    /// a session with a tracking jump closed to 7 cm; one without, to 1.5 cm).
    public static let loopTolerance: Float = 0.2
    public static let loopTurn: Float = 8 * .pi / 180

    public init() {}

    public enum Added: Equatable, Sendable {
        /// A new pair of sessions joined.
        case joined
        /// A stronger link for a pair already joined.
        case replaced
        /// Not stronger than the link the pair has.
        case weaker
        /// It closes a loop that disagrees with the chain it bypasses by this much (metres): refused.
        case refused(Float)
    }

    /// Adds a link between two sessions (kept if it is the strongest for the pair, and agrees with
    /// the chain between them if there already is one).
    @discardableResult
    public mutating func add(_ edge: Edge) -> Added {
        guard edge.from != edge.to else { return .weaker }
        let existing = edges.firstIndex { ($0.from == edge.from && $0.to == edge.to) || ($0.from == edge.to && $0.to == edge.from) }
        if let i = existing {
            guard edge.matches > edges[i].matches else { return .weaker }
            edges[i] = edge
            return .replaced
        }
        // A loop: the chain already joining the two must agree with the new link at its evidence.
        if let chain = transform(from: edge.from, to: edge.to) {
            let apart = chain.distance(to: edge.transform, at: edge.centre)
            guard apart <= Self.loopTolerance, chain.turn(to: edge.transform) <= Self.loopTurn else { return .refused(apart) }
        }
        edges.append(edge)
        return .joined
    }

    /// Drops the link between two sessions (the live session's tracking broke and it was linked
    /// afresh: its coordinates may have moved, so the new link replaces the old whatever its strength).
    public mutating func removeLink(between a: UUID, and b: UUID) {
        edges.removeAll { ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a) }
    }

    /// The link between two sessions, carrying points of `a` into `b`, if they have one.
    public func link(from a: UUID, to b: UUID) -> Edge? {
        edges.first { $0.from == a && $0.to == b } ?? edges.first { $0.from == b && $0.to == a }?.reversed
    }

    /// Drops the links of `session` made before `date` (its coordinates moved since then: the live
    /// session's tracking broke and a link made afresh shows it moved).
    public mutating func removeLinks(of session: UUID, madeBefore date: Date) {
        edges.removeAll { ($0.from == session || $0.to == session) && $0.made < date }
    }

    /// The sessions joined to `session` (itself included).
    public func component(of session: UUID) -> Set<UUID> {
        var seen: Set<UUID> = [session]
        var todo = [session]
        while let s = todo.popLast() {
            for e in edges where e.from == s || e.to == s {
                let other = e.from == s ? e.to : e.from
                if seen.insert(other).inserted { todo.append(other) }
            }
        }
        return seen
    }

    /// Carries points of session `a` into session `b` along the strongest chain, if they are joined.
    public func transform(from a: UUID, to b: UUID) -> UprightTransform? {
        if a == b { return .identity }
        guard let path = strongestPath(from: a, to: b) else { return nil }
        return path.reduce(UprightTransform.identity) { $0.then($1.transform) }
    }

    /// The edges from `a` to `b` (each oriented along the way) in the spanning tree built strongest
    /// link first (Kruskal): the chain of the strongest links that joins them.
    public func strongestPath(from a: UUID, to b: UUID) -> [Edge]? {
        // The tree.
        var parent: [UUID: UUID] = [:]
        func find(_ x: UUID) -> UUID {
            var r = x
            while let p = parent[r], p != r { r = p }
            return r
        }
        var tree: [Edge] = []
        for e in edges.sorted(by: { $0.matches > $1.matches }) {
            let ra = find(e.from), rb = find(e.to)
            if parent[ra] == nil { parent[ra] = ra }
            if parent[rb] == nil { parent[rb] = rb }
            guard ra != rb else { continue }
            parent[ra] = rb
            tree.append(e)
        }
        // The path in it, breadth first.
        var previous: [UUID: Edge] = [:]
        var seen: Set<UUID> = [a]
        var queue = [a]
        while !queue.isEmpty {
            let s = queue.removeFirst()
            if s == b { break }
            for e in tree where e.from == s || e.to == s {
                let step = e.from == s ? e : e.reversed
                if seen.insert(step.to).inserted {
                    previous[step.to] = step
                    queue.append(step.to)
                }
            }
        }
        guard seen.contains(b) else { return nil }
        var path: [Edge] = []
        var at = b
        while at != a, let step = previous[at] {
            path.insert(step, at: 0)
            at = step.from
        }
        return path
    }
}
