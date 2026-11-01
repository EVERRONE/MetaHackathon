import ARKit
import Foundation
import PipCore
import UIKit
import simd

/// Links this session to the stored sessions of the same place, in the background
/// (docs/spatial-memory.md), without ever touching the live session.
///
/// Every 1.5 s a sharp live view (settled tracking) is described (FeatureMatcher) and its corners
/// are lifted to this session's room at their LiDAR depth; it is matched with stored snapshots of
/// other sessions, a batch at a time (SessionLink). A stored session is linked once two live views
/// agree on where it is; more view links keep coming and carry its points better near them. A
/// stored snapshot's pose is carried by the links nearest to what it saw (its own first): a
/// session's own coordinates drift (1 Nov: 11-12 cm between two snapshots a few seconds apart).
@MainActor
final class SpaceLinker {
    struct Linked {
        /// View links that may carry the session's points: the agreeing core and those within its drift.
        var links: [ViewLink]
        var views: Int
        var matches: Int
    }

    /// A stored session became linked (`first`), got more evidence, or was linked afresh after the
    /// live session's tracking broke.
    var onLinked: ((UUID, Linked, _ first: Bool) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var linked: [UUID: Linked] = [:]

    /// The stored snapshots that may be linked to (ViewLink.from indexes them), and their corners.
    private var stored: [Keyframes.Frame] = []
    private var described: [Int: ViewPoints] = [:]
    /// Snapshots of sessions elsewhere on earth: never matched (a look-alike shop is not the home).
    private var excluded = Set<Int>()
    private var describing = Set<Int>()
    private var undescribable = Set<Int>()
    /// View links found so far, per stored session (ViewLink.to numbers the live views).
    private var found: [UUID: [ViewLink]] = [:]
    private var cursor = 0
    private var liveViews = 0
    private var lastView: TimeInterval = 0
    private var working = false
    /// Bumped when the live session's coordinates may have moved: work started before is dropped.
    private var epoch = 0
    private var timer: Timer?

    private let queue = DispatchQueue(label: "pip.spacelinker", qos: .utility)
    nonisolated static let settings = SessionLink.Settings()
    static let interval: TimeInterval = 1.5
    /// Stored snapshots matched with each live view (about 1-2 ms each).
    static let comparePerView = 60
    /// Stored snapshots described per round (about 30 ms each).
    static let describePerRound = 4

    /// The stored snapshots of other sessions to link to: newest first (the room as it is now).
    func begin(with frames: [Keyframes.Frame]) {
        stored = frames.sorted { $0.time > $1.time }
        described = [:]
        describing = []
        undescribable = []
        found = [:]
        linked = [:]
        cursor = 0
        let sessions = Set(stored.compactMap(\.piece)).count
        onLog?("space: \(stored.count) snapshots of \(sessions) earlier sessions to link this one to")
        timer?.invalidate()
        guard !stored.isEmpty else { return }
        // The stored snapshots are described in the background, a few at a time.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.describeSome() }
        }
    }

    private func describeSome() {
        let todo = stored.indices.filter { described[$0] == nil && !describing.contains($0) && !undescribable.contains($0) && !excluded.contains($0) }
            .prefix(Self.describePerRound)
        guard !todo.isEmpty else {
            if describing.isEmpty { timer?.invalidate(); timer = nil }
            return
        }
        for i in todo {
            describing.insert(i)
            let frame = stored[i]
            queue.async { [weak self] in
                let points = Self.describe(frame)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.describing.remove(i)
                    if let points { self.described[i] = points } else { self.undescribable.insert(i) }
                }
            }
        }
    }

    /// A stored snapshot's corners, lifted in its own session's coordinates.
    nonisolated private static func describe(_ frame: Keyframes.Frame) -> ViewPoints? {
        guard let jpeg = frame.jpeg(), let image = UIImage(data: jpeg)?.cgImage, let grey = GrayImage(image),
              let grid = frame.depthGrid() else { return nil }
        return ViewPoints(image: grey) { p in frame.storedPoint(atPixel: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)), grid: grid) }
    }

    /// A camera frame: every 1.5 s a sharp one (settled tracking) is matched with the next batch of
    /// stored snapshots, in the background.
    func consider(_ frame: ARFrame, gate: CaptureGate) {
        guard !working, !described.isEmpty, frame.timestamp - lastView >= Self.interval else { return }
        guard case .normal = frame.camera.trackingState, gate.accepts(frame) else { return }
        lastView = frame.timestamp
        working = true
        liveViews += 1
        let view = liveViews, epoch = self.epoch
        // The next stored snapshots in turn (all of them come round every few seconds).
        let ready = described.keys.filter { !excluded.contains($0) }.sorted()
        var batch: [(Int, ViewPoints)] = []
        for k in 0..<min(Self.comparePerView, ready.count) {
            let i = ready[(cursor + k) % ready.count]
            if let p = described[i] { batch.append((i, p)) }
        }
        cursor = (cursor + batch.count) % max(ready.count, 1)
        queue.async { [weak self] in
            var links: [ViewLink] = []
            if let snap = FrameSnapshot(frame: frame, maxSide: 768), let live = Self.liveView(snap) {
                for (i, points) in batch {
                    if let l = SessionLink.link(points, live, from: i, to: view, settings: Self.settings) { links.append(l) }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.working = false
                guard self.epoch == epoch else { return }
                self.add(links)
            }
        }
    }

    /// The live view's corners, lifted in this session's coordinates where the depth is trustworthy
    /// (the same rule as for stored snapshots).
    nonisolated private static func liveView(_ snap: FrameSnapshot) -> ViewPoints? {
        guard let grey = GrayImage(snap.image) else { return nil }
        // About one depth pixel apart round the point (the depth map is 256 × 192).
        let step = CGFloat(snap.image.height) / 256
        return ViewPoints(image: grey) { p in
            var s: [Float] = []
            for dy in -1...1 {
                for dx in -1...1 {
                    let q = CGPoint(x: CGFloat(p.x) + CGFloat(dx) * step, y: CGFloat(p.y) + CGFloat(dy) * step)
                    if let d = snap.depth(atSensor: snap.sensorPoint(q)), d > 0.1, d < 6 { s.append(d) }
                }
            }
            guard s.count >= 5 else { return nil }
            s.sort()
            guard s.last! - s.first! < 0.05 else { return nil }
            return snap.worldPoint(sensor: snap.sensorPoint(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))), depth: s[s.count / 2])
        }
    }

    private func add(_ links: [ViewLink]) {
        guard !links.isEmpty else { return }
        var touched = Set<UUID>()
        for l in links {
            guard let piece = stored[l.from].piece else { continue }
            found[piece, default: []].append(l)
            touched.insert(piece)
        }
        for piece in touched {
            let all = found[piece] ?? []
            guard let core = SessionLink.consensus(all, settings: Self.settings) else { continue }
            let usable = SessionLink.usable(all, core: core, settings: Self.settings)
            let link = Linked(links: usable, views: Set(core.map(\.to)).count, matches: core.reduce(0) { $0 + $1.inliers })
            let first = linked[piece] == nil
            linked[piece] = link
            if first {
                let rejected = all.count - usable.count
                onLog?(String(format: "space: linked to the session of %@ by %d live views (%d matches; %d view links within drift, %d rejected): %@",
                              Self.when(piece, in: stored), link.views, link.matches, usable.count, rejected, core[0].transform.description))
            }
            onLinked?(piece, link, first)
        }
    }

    /// Only sessions mapped at this place on earth (`here` decides for each session; sessions without a
    /// location stay): known once the location comes in, a second or two after start.
    func keepOnly(_ here: (UUID) -> Bool) {
        var dropped = Set<UUID>()
        for (i, f) in stored.enumerated() {
            guard let piece = f.piece, !here(piece) else { continue }
            excluded.insert(i)
            dropped.insert(piece)
        }
        for piece in dropped {
            found[piece] = nil
            linked[piece] = nil
        }
        if !dropped.isEmpty { onLog?("space: \(dropped.count) earlier sessions were mapped elsewhere; not linked to") }
    }

    /// The live session's tracking broke or jumped: its coordinates may have moved. Evidence is
    /// gathered afresh; the links in use stay until new ones replace them (a brief loss usually
    /// moves nothing, and dropping every place at each one would make them flicker).
    func trackingBroke() {
        guard !found.isEmpty else { return }
        epoch += 1
        found = [:]
        if !linked.isEmpty { onLog?("space: tracking broke; the links to earlier sessions are checked afresh") }
    }

    /// A stored snapshot's pose in this session: carried by the link of that very snapshot if it has
    /// one, else by the links nearest to what it saw. Nil when its session is not linked.
    func carriedPose(of frame: Keyframes.Frame) -> simd_float4x4? {
        guard let piece = frame.piece, let link = linked[piece], let index = stored.firstIndex(where: { $0.id == frame.id }) else { return nil }
        let own = link.links.filter { $0.from == index }.max { $0.inliers < $1.inliers }
        // What it saw: a metre ahead of the camera.
        let ahead = simd_make_float3(frame.storedPose * SIMD4(0, 0, -1, 1))
        guard let l = own ?? SessionLink.nearest(ahead, in: link.links) else { return nil }
        return l.transform.matrix * frame.storedPose
    }

    /// A point of a stored session in this session (a remembered place), by the links nearest it.
    func carry(_ p: simd_float3, of piece: UUID) -> simd_float3? {
        linked[piece].flatMap { SessionLink.carry(p, by: $0.links) }
    }

    /// A pose of a stored session in this session, turned and shifted by the link nearest its position.
    func carry(pose: simd_float4x4, of piece: UUID) -> simd_float4x4? {
        guard let link = linked[piece], let l = SessionLink.nearest(simd_make_float3(pose.columns.3), in: link.links) else { return nil }
        return l.transform.matrix * pose
    }

    private static func when(_ piece: UUID, in frames: [Keyframes.Frame]) -> String {
        guard let t = frames.filter({ $0.piece == piece }).map(\.time).min() else { return String(piece.uuidString.prefix(4)) }
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: t) + " (" + String(piece.uuidString.prefix(4)) + ")"
    }
}
