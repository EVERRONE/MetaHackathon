import CoreGraphics
import Foundation
import Vision
import simd

// The decisions of linking the live session to earlier ones (docs/spatial-memory.md), kept apart
// from threads, cameras and storage, so that the app (SpaceLinker) and the offline replay
// (`pipeval livelink`) run the very same code, and tests pin it down.

/// Which depth to trust at a pixel: the samples round it (LiDAR, metres). Five or more within the
/// LiDAR's range, spread over less than 5 cm (not across a depth edge, where a corner's depth is
/// either side's), their median. One rule for stored snapshots and live views alike.
public enum TrustedDepth {
    public static let range: ClosedRange<Float> = 0.1...6
    public static let minSamples = 5
    public static let maxSpread: Float = 0.05

    public static func of(_ samples: [Float]) -> Float? {
        let s = samples.filter { range.contains($0) }.sorted()
        guard s.count >= minSamples, let lo = s.first, let hi = s.last, hi - lo < maxSpread else { return nil }
        return s[s.count / 2]
    }
}

/// View links gathered live, per earlier session, and what they say: which sessions are linked, and
/// where their points and views are in the live session.
///
/// One per live session. Evidence counts only since the live session's coordinates were last
/// trusted: a tracking break may move them, so evidence gathered before it is set aside, while the
/// links in use stay until evidence after the break replaces them (a brief loss usually moves
/// nothing, and dropping every place at each one would make them flicker).
public struct LinkBook: Sendable {
    public struct Linked: Sendable, Equatable {
        /// The view links that agree and made the link.
        public var core: [ViewLink]
        /// Those that may carry points: the core, and view links within the sessions' drift of it.
        public var usable: [ViewLink]
        public var views: Int { Set(core.map(\.to)).count }
        public var matches: Int { core.reduce(0) { $0 + $1.inliers } }
        public var extent: Float { SessionLink.extent(core) }
    }

    public enum Change: Sendable, Equatable {
        /// Linked for the first time.
        case linked
        /// Linked again after the live session's tracking broke (the link may have moved).
        case relinked
        /// More evidence for a link in use.
        case strengthened
    }

    public let settings: SessionLink.Settings
    /// Evidence since the last tracking break, per earlier session (the strongest kept).
    private var evidence: [UUID: [ViewLink]] = [:]
    public private(set) var linked: [UUID: Linked] = [:]
    /// The tracking break each link was made after (so a link made again after a break is told apart).
    private var linkedAfterBreak: [UUID: Int] = [:]
    public private(set) var breaks = 0
    /// Stored views (their numbers) that gave view links lately, newest last.
    private var recent: [Int] = []

    /// Evidence kept per session: the strongest view links (agreement is checked pairwise).
    public static let maxEvidence = 240

    public init(settings: SessionLink.Settings = SessionLink.Settings()) {
        self.settings = settings
    }

    /// The view links of one live view (each with the earlier session its stored view belongs to).
    /// Returns what changed, per session.
    public mutating func add(_ links: [(session: UUID, link: ViewLink)]) -> [UUID: Change] {
        var touched = Set<UUID>()
        for (session, link) in links {
            evidence[session, default: []].append(link)
            touched.insert(session)
            recent.append(link.from)
        }
        if recent.count > 60 { recent.removeFirst(recent.count - 60) }
        var changes: [UUID: Change] = [:]
        for session in touched {
            var ev = evidence[session] ?? []
            if ev.count > Self.maxEvidence {
                ev = Array(ev.sorted { $0.inliers > $1.inliers }.prefix(Self.maxEvidence))
                evidence[session] = ev
            }
            guard let core = SessionLink.consensus(ev, settings: settings) else { continue }
            let now = Linked(core: core, usable: SessionLink.usable(ev, core: core, settings: settings))
            if linked[session] == nil {
                changes[session] = .linked
            } else if linkedAfterBreak[session] != breaks {
                changes[session] = .relinked
            } else if now != linked[session] {
                changes[session] = .strengthened
            }
            linked[session] = now
            linkedAfterBreak[session] = breaks
        }
        return changes
    }

    /// The live session's tracking broke or jumped: evidence gathered before counts no longer.
    public mutating func trackingBroke() {
        breaks += 1
        evidence = [:]
        recent = []
    }

    /// Stored views to match first: those that gave view links lately (newest first), each with its
    /// neighbours in its session (`neighbours`): where the live view probably is.
    public func hot(limit: Int, neighbours: (Int) -> [Int]) -> [Int] {
        var out: [Int] = []
        var seen = Set<Int>()
        for v in recent.reversed() {
            for w in [v] + neighbours(v) where seen.insert(w).inserted {
                out.append(w)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// A pose of an earlier session in the live session: by the strongest link of that very stored
    /// view (`view`) if it has one, else by the link whose evidence is nearest `near` (what a camera
    /// looked at, where an anchor is). Each session drifts: a link holds best near its own evidence.
    public func carry(pose: simd_float4x4, of session: UUID, view: Int? = nil, near: SIMD3<Float>) -> simd_float4x4? {
        guard let usable = linked[session]?.usable else { return nil }
        let own = view.flatMap { v in usable.filter { $0.from == v }.max { $0.inliers < $1.inliers } }
        guard let link = own ?? SessionLink.nearest(near, in: usable) else { return nil }
        return link.transform.matrix * pose
    }

    /// What a camera at `pose` looked at: a metre ahead of it.
    public static func lookedAt(_ pose: simd_float4x4) -> SIMD3<Float> {
        simd_make_float3(pose * SIMD4<Float>(0, 0, -1, 1))
    }
}

/// An image's fingerprint (Apple Vision's feature print): which stored views look like a live one.
/// Matching by described corners is exact but costs a millisecond or two per pair; the fingerprint
/// finds the few worth it (1 Nov, on the user's sessions: of 13 live views that linked, the stored
/// view they link to came first by fingerprint for 11, within the first 10 for 12, within 40 for all).
public struct ViewPrint: @unchecked Sendable {
    let observation: VNFeaturePrintObservation

    public init?(_ image: CGImage) {
        let request = VNGenerateImageFeaturePrintRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
              let o = request.results?.first as? VNFeaturePrintObservation else { return nil }
        observation = o
    }

    public func distance(to other: ViewPrint) -> Float {
        var d: Float = .infinity
        try? observation.computeDistance(&d, to: other.observation)
        return d
    }

    /// The `count` views of `among` that look most like `self`, nearest first.
    public func nearest(_ count: Int, among: [Int: ViewPrint]) -> [Int] {
        among.map { ($0.key, distance(to: $0.value)) }.sorted { $0.1 < $1.1 }.prefix(count).map(\.0)
    }
}

/// Which stored views a live view is matched with: those that look most like it (`ViewPrint`), then
/// the hot ones (`LinkBook.hot`), then the rest in turn, so every stored view comes round.
public struct LinkSchedule: Sendable {
    public private(set) var cursor = 0

    public init() {}

    /// `ready`: the stored views that can be matched (described, of this place on earth), in order.
    public mutating func next(ready: [Int], lookAlike: [Int] = [], hot: [Int], count: Int) -> [Int] {
        guard !ready.isEmpty, count > 0 else { return [] }
        let allowed = Set(ready)
        var out: [Int] = []
        var seen = Set<Int>()
        for v in lookAlike + hot where allowed.contains(v) && seen.insert(v).inserted {
            out.append(v)
            if out.count >= count { return out }
        }
        var k = 0
        while out.count < count, k < ready.count {
            let v = ready[(cursor + k) % ready.count]
            if seen.insert(v).inserted { out.append(v) }
            k += 1
        }
        cursor = (cursor + k) % ready.count
        return out
    }
}
