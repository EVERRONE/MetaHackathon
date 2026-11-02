import ARKit
import Foundation
import PipCore
import UIKit
import simd

/// Links this session to the earlier sessions of the same place, in the background
/// (docs/spatial-memory.md), without ever touching the live session.
///
/// The decisions are PipCore's (`SessionLink`, `LinkBook`, `LinkSchedule`), the same code
/// `pipeval livelink` replays on stored sessions. This shell reads and describes the stored
/// snapshots, describes a sharp live view every 1.5 s, matches it with the next batch of stored
/// views on a queue of its own, and reports what changed and what it measured.
@MainActor
final class SpaceLinker {
    /// An earlier session was linked, linked again after a tracking break, or got more evidence.
    var onChange: ((UUID, LinkBook.Change) -> Void)?
    var onLog: ((String) -> Void)?
    /// A line for the screen: what linking is doing.
    var onStatus: ((String) -> Void)?

    private(set) var book = LinkBook()
    private var schedule = LinkSchedule()
    /// Stored snapshots of earlier sessions, by session, then in the order they were taken: a view's
    /// neighbours in its session sit next to it. Their numbers are ViewLink.from.
    private var stored: [Keyframes.Frame] = []
    private var number: [UUID: Int] = [:]
    private var described: [Int: ViewPoints] = [:]
    /// Their fingerprints: which ones look like a live view.
    private var prints: [Int: ViewPrint] = [:]
    private var describing = Set<Int>()
    private var undescribable = Set<Int>()
    /// Sessions mapped elsewhere on earth: never matched.
    private var elsewhere = Set<Int>()
    private var liveViews = 0
    private var lastView: TimeInterval = 0
    private var working = false
    /// Tracking breaks seen: matching started before one is dropped.
    private var breaks = 0
    /// Bumped by `begin`: work started before (describing, matching) is dropped when it comes back,
    /// so a stored view's number never meets another set of stored views.
    private var generation = 0
    private var describeTimer: Timer?

    // What it measured, for the log.
    private var describeMs: [Double] = []
    private var viewMs: [Double] = []
    private var viewLinksSince = 0
    private var viewsSince = 0
    private var lastSummary = Date()

    private let queue = DispatchQueue(label: "pip.spacelinker", qos: .utility)

    static let interval: TimeInterval = 1.5
    /// Stored views matched with each live view (about 1-2 ms each), the hot ones first.
    static let comparePerView = 60
    static let hotPerView = 24
    /// Of those, the ones that look most like the live view (fingerprint), first.
    nonisolated static let lookAlikePerView = 20
    /// Stored snapshots described per half second at start (about 20-40 ms each).
    static let describePerRound = 4
    static let summaryEvery: TimeInterval = 60

    var linked: [UUID: LinkBook.Linked] { book.linked }

    /// The stored snapshots of earlier sessions to link this one to.
    func begin(with frames: [Keyframes.Frame]) {
        generation += 1
        stored = frames.sorted { ($0.piece?.uuidString ?? "", $0.time) < ($1.piece?.uuidString ?? "", $1.time) }
        number = Dictionary(uniqueKeysWithValues: stored.enumerated().map { ($1.id, $0) })
        book = LinkBook()
        schedule = LinkSchedule()
        described = [:]
        prints = [:]
        describing = []
        undescribable = []
        elsewhere = []
        let sessions = Set(stored.compactMap(\.piece)).count
        onLog?("space: \(stored.count) snapshots of \(sessions) earlier sessions to link this one to")
        describeTimer?.invalidate()
        describeTimer = nil
        startDescribing()
    }

    /// Describes the stored snapshots not described yet, a few every half second.
    private func startDescribing() {
        guard describeTimer == nil, !stored.isEmpty else { return }
        describeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.describeSome() }
        }
    }

    /// Only sessions mapped at this place on earth (`here` decides per session; without a location
    /// a session stays), once the location is known. Decided afresh with every fix: the first can
    /// be an old one from elsewhere (the phone's last fix, up to ten minutes old), and sessions it
    /// ruled out are linked to again once a fix says they are of here.
    func keepOnly(_ here: (UUID) -> Bool) {
        var now = Set<Int>(), dropped = Set<UUID>()
        for (i, f) in stored.enumerated() {
            guard let piece = f.piece, !here(piece) else { continue }
            now.insert(i)
            dropped.insert(piece)
        }
        let back = Set(elsewhere.subtracting(now).compactMap { stored[$0].piece })
        let newlyDropped = Set(now.subtracting(elsewhere).compactMap { stored[$0].piece })
        elsewhere = now
        // Said when it changes, not with every fix (2 Nov: the same line five to seven times at each start).
        if !newlyDropped.isEmpty { onLog?("space: \(dropped.count) earlier sessions were mapped elsewhere; not linked to") }
        if !back.isEmpty {
            onLog?("space: \(back.count) earlier sessions are of this place after all; linked to again")
            startDescribing()
        }
    }

    private func describeSome() {
        let todo = Array(stored.indices.lazy.filter {
            self.described[$0] == nil && !self.describing.contains($0) && !self.undescribable.contains($0) && !self.elsewhere.contains($0)
        }.prefix(Self.describePerRound))
        guard !todo.isEmpty else {
            if describing.isEmpty {
                describeTimer?.invalidate()
                describeTimer = nil
                let ms = describeMs.sorted()
                onLog?(String(format: "space: %d stored snapshots described (%.0f ms each, median), %d without usable depth",
                              described.count, ms.isEmpty ? 0 : ms[ms.count / 2], undescribable.count))
            }
            return
        }
        let generation = self.generation
        for i in todo {
            describing.insert(i)
            let frame = stored[i]
            queue.async { [weak self] in
                let t0 = Date()
                let described = Self.describe(frame)
                let ms = Date().timeIntervalSince(t0) * 1000
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else { return }
                    self.describing.remove(i)
                    self.describeMs.append(ms)
                    if let described {
                        self.described[i] = described.points
                        self.prints[i] = described.print
                    } else {
                        self.undescribable.insert(i)
                    }
                }
            }
        }
    }

    /// A stored snapshot's corners, lifted in its own session's coordinates (the pose it was taken
    /// at), and its fingerprint.
    nonisolated private static func describe(_ frame: Keyframes.Frame) -> (points: ViewPoints, print: ViewPrint?)? {
        guard let jpeg = frame.jpeg(), let image = UIImage(data: jpeg)?.cgImage, let grey = GrayImage(image),
              let grid = frame.depthGrid() else { return nil }
        let points = ViewPoints(image: grey, camera: simd_make_float3(frame.storedPose.columns.3)) { p in
            frame.storedPoint(atPixel: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)), grid: grid)
        }
        return (points, ViewPrint(image))
    }

    /// A camera frame: every 1.5 s a sharp one (settled tracking) is described and fingerprinted in
    /// the background; the stored views that look most like it, the hot ones and the next in turn
    /// are chosen here (LinkSchedule, as `pipeval livelink` does), and matched in the background.
    func consider(_ frame: ARFrame, gate: CaptureGate) {
        guard !working, !described.isEmpty, frame.timestamp - lastView >= Self.interval else { return }
        guard case .normal = frame.camera.trackingState, gate.accepts(frame) else { return }
        lastView = frame.timestamp
        working = true
        liveViews += 1
        let view = liveViews, breaks = self.breaks, generation = self.generation
        let prints = self.prints.filter { !elsewhere.contains($0.key) }
        queue.async { [weak self] in
            let t0 = Date()
            guard let snap = FrameSnapshot(frame: frame, maxSide: 768), let live = Self.liveView(snap) else {
                DispatchQueue.main.async { self?.working = false }
                return
            }
            let lookAlike = ViewPrint(snap.image)?.nearest(Self.lookAlikePerView, among: prints) ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.breaks == breaks, self.generation == generation else { self.working = false; return }
                self.match(live, view: view, lookAlike: lookAlike, breaks: breaks, started: t0)
            }
        }
    }

    private func match(_ live: ViewPoints, view: Int, lookAlike: [Int], breaks: Int, started t0: Date) {
        let ready = described.keys.filter { !elsewhere.contains($0) }.sorted()
        let all = stored
        let hot = book.hot(limit: Self.hotPerView) { v in Self.neighbours(of: v, in: all) }
        let batch = schedule.next(ready: ready, lookAlike: lookAlike, hot: hot, count: Self.comparePerView).compactMap { i in described[i].map { (i, $0) } }
        let sessions = batch.map { stored[$0.0].piece }
        let settings = book.settings, generation = self.generation
        queue.async { [weak self] in
            var links: [(Int, ViewLink)] = []
            for (k, (i, points)) in batch.enumerated() {
                if let l = SessionLink.link(points, live, from: i, to: view, settings: settings) { links.append((k, l)) }
            }
            let ms = Date().timeIntervalSince(t0) * 1000
            DispatchQueue.main.async {
                guard let self else { return }
                self.working = false
                self.viewMs.append(ms)
                self.viewsSince += 1
                // A tracking break meanwhile: this view may be in other coordinates. Or everything
                // was forgotten: these stored views are gone.
                guard self.breaks == breaks, self.generation == generation else { return }
                self.viewLinksSince += links.count
                let found = links.compactMap { k, l in sessions[k].map { (session: $0, link: l) } }
                for (session, change) in self.book.add(found) { self.report(session, change) }
                self.summariseIfDue()
            }
        }
    }

    /// The live view's corners, lifted in this session's coordinates by the same depth rule as the
    /// stored snapshots (the depth map's pixels round each corner).
    nonisolated private static func liveView(_ snap: FrameSnapshot) -> ViewPoints? {
        guard let grey = GrayImage(snap.image) else { return nil }
        // About one depth pixel apart (the depth map is 256 × 192).
        let step = CGFloat(snap.image.height) / 256
        return ViewPoints(image: grey, camera: simd_make_float3(snap.cameraTransform.columns.3)) { p in
            var samples: [Float] = []
            for dy in -1...1 {
                for dx in -1...1 {
                    let q = CGPoint(x: CGFloat(p.x) + CGFloat(dx) * step, y: CGFloat(p.y) + CGFloat(dy) * step)
                    if let d = snap.depth(atSensor: snap.sensorPoint(q)) { samples.append(d) }
                }
            }
            guard let d = TrustedDepth.of(samples) else { return nil }
            return snap.worldPoint(sensor: snap.sensorPoint(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))), depth: d)
        }
    }

    /// A stored view's neighbours in its own session (two each way).
    nonisolated private static func neighbours(of v: Int, in stored: [Keyframes.Frame]) -> [Int] {
        [v - 1, v + 1, v - 2, v + 2].filter { stored.indices.contains($0) && stored[$0].piece == stored[v].piece }
    }

    private func report(_ session: UUID, _ change: LinkBook.Change) {
        guard let l = book.linked[session] else { return }
        if change != .strengthened, let core = l.core.max(by: { $0.inliers < $1.inliers }) {
            onLog?(String(format: "space: %@ the session of %@: %d live views agree (%d matches, over %.1f m of the room; %d view links usable): %@",
                          change == .linked ? "linked to" : "linked again after a tracking break to", when(session), l.views, l.matches, l.extent,
                          l.usable.count, core.transform.description))
        }
        onStatus?(status())
        onChange?(session, change)
    }

    private func summariseIfDue() {
        guard Date().timeIntervalSince(lastSummary) >= Self.summaryEvery else { return }
        lastSummary = Date()
        let ms = viewMs.sorted()
        let linkedNow = book.linked.isEmpty ? "none yet" : book.linked.map { "\(when($0.key)) (\($0.value.views) views)" }.joined(separator: ", ")
        onLog?(String(format: "space: %d live views in the last minute, %d view links; %.0f ms per live view (median); linked: %@",
                      viewsSince, viewLinksSince, ms.isEmpty ? 0 : ms[ms.count / 2], linkedNow))
        viewsSince = 0
        viewLinksSince = 0
        viewMs = []
        onStatus?(status())
    }

    private func status() -> String {
        book.linked.isEmpty ? "space: looking (\(liveViews) views)" : "space: " + book.linked.keys.map { "\(when($0)) ✓" }.joined(separator: ", ")
    }

    /// When the live session's tracking last broke (links made before may be in other coordinates).
    private(set) var lastBreak: Date?

    /// The live session's tracking broke or jumped: its coordinates may have moved (LinkBook).
    func trackingBroke() {
        breaks += 1
        lastBreak = Date()
        book.trackingBroke()
    }

    /// A stored snapshot's pose in this session: by its own link if it has one, else by the link
    /// nearest what it looked at. Nil when its session is not linked.
    func carriedPose(of frame: Keyframes.Frame) -> simd_float4x4? {
        guard let piece = frame.piece else { return nil }
        return book.carry(pose: frame.storedPose, of: piece, view: number[frame.id], near: LinkBook.lookedAt(frame.storedPose))
    }

    /// A remembered place's anchor (its earlier session's coordinates) in this session, by the link
    /// nearest the place.
    func carry(anchor: simd_float4x4, of piece: UUID) -> simd_float4x4? {
        book.carry(pose: anchor, of: piece, near: simd_make_float3(anchor.columns.3))
    }

    private func when(_ piece: UUID) -> String {
        guard let t = stored.filter({ $0.piece == piece }).map(\.time).min() else { return String(piece.uuidString.prefix(4)) }
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: t) + " (" + String(piece.uuidString.prefix(4)) + ")"
    }
}
