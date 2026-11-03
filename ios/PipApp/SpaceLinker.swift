import ARKit
import CoreML
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
    /// The place looks known (DINOv2's whole-view likeness to stored views), but no session is linked
    /// after `lookAroundAfter`: the user can help by looking round (said once a session). 2 Nov, at
    /// the round table: likeness 0.85-0.93 for two minutes, linked once the island came into view.
    var onLookAround: (() -> Void)?
    static let lookAroundAfter: TimeInterval = 8
    static let lookAroundLikeness: Float = 0.85
    private var firstDino: Date?
    private var likeness: [Float] = []
    private var lookAroundAsked = false

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
    /// Whether the kept corner descriptions were read: none is described before (it may be on disk).
    private var cornersRead = true

    // What it measured, for the log.
    private var describeMs: [Double] = []
    private var viewMs: [Double] = []
    private var viewLinksSince = 0
    private var viewsSince = 0
    private var lastSummary = Date()

    private let queue = DispatchQueue(label: "pip.spacelinker", qos: .utility)

    // Across a change of light (DinoLink: Meta's DINOv2, then the depth). The described corners
    // link sessions in the same light; on 2 Nov the same rooms at 15:22 and at 16:40 in low sun gave
    // one corner view link, and the session was never linked. This runs beside them, on a queue of
    // its own (the corners' start is not held up), every few seconds.
    /// Whether the app has the model (looked up without loading it).
    nonisolated private static let hasModel = Bundle.main.url(forResource: ViewFeatures.modelName, withExtension: "mlmodelc") != nil
    /// The model (Models/DINOv2, see ios/scripts/convert-dinov2.py), loaded on first use on a
    /// background queue after `dinoDelay`, and loaded again when Core ML failed (2 Nov, 18:09: it
    /// was not loaded, silently, and the session ran without it).
    private let dino = DinoModel()
    private let dinoQueue = DispatchQueue(label: "pip.spacelinker.dino", qos: .utility)
    /// The stored snapshots' whole-view tokens are made here, one at a time, at the lowest priority.
    private let wholesQueue = DispatchQueue(label: "pip.spacelinker.wholes", qos: .background)
    /// Each stored snapshot's whole-view token: which stored views look like a live view, whatever the
    /// light. Kept beside the snapshots (VisualMemoryStore.whole), read at the start: made once, not
    /// at every start (2 Nov, 18:36: made again one per 0.25 s, the newest snapshots first, so an
    /// earlier session's bathroom views were there 30 s in, as the user left the bathroom, and the
    /// session was linked 53 s in, from the hall. Replayed (`pipeval dinolive`, its snapshots as
    /// live views): as built, linked 72 s in; with the tokens there from the start, every live view
    /// while searching and DINOv2 from 5 s on, 26 s in, in the bathroom, at -57.8° like the desk's).
    private var wholes: [Int: [Float]] = [:]
    /// Stored snapshots waiting for their whole-view token, and whether one is being made.
    private var wholesPending: [Int] = []
    private var wholeInFlight = false
    private var wholesTimer: Timer?
    /// Whether the kept tokens were read: none is made before (it may be on disk).
    private var wholesRead = false
    private var wholesMade = 0
    private var wholesBegan = Date()
    /// This session's own snapshots, whose tokens are made for the sessions after it (`noteKept`).
    private var ownPending: [Keyframes.Frame] = []
    /// DINOv2 starts this long after a session: EdgeTAM loads first, and the speech gets going (2 Nov,
    /// 17:59: all stored snapshots described with DINOv2 at once, EdgeTAM failed to load three times
    /// and the speech service fell behind the audio). With the stored tokens kept, a start makes none
    /// (only once after this was built), and EdgeTAM is loaded 1 s in (2 Nov, 19:03-19:09: 0.9-1.1 s).
    /// Replayed on the bathroom start of 18:36, from 3 s in a session was linked at 8.7 s (from 5 s
    /// in, at 14.2 s).
    static let dinoDelay: TimeInterval = 1.5
    private var dinoStart = Date.distantFuture
    /// One stored snapshot's whole-view token this often, at most.
    static let wholeEvery: TimeInterval = 0.25
    /// Stored views prepared for DinoLink, the last few used (used on `dinoQueue` only).
    private let dinoViews = DinoViews()
    private var lastDino: TimeInterval = 0
    private var dinoWorking = false
    private var dinoLinksSince = 0
    private var dinoMs: [Double] = []
    static let dinoInterval: TimeInterval = 3
    /// Until a session is linked (in the first `searchFor` of a session), one live view after the
    /// other, at a pace of its own (each takes 0.2-0.5 s), not with the corners' views every 1.5 s:
    /// how soon Pip knows where it is depends on how many views it lays (2 Nov, replayed: every
    /// snapshot laid linked the bathroom of 18:36 in 8.7 s, every 1.5 s in 25.6 s).
    static let dinoIntervalSearching: TimeInterval = 0.3
    static let searchFor: TimeInterval = 90
    /// Stored views a live view is laid against: the most alike by DINOv2's whole-view token; more
    /// while no session is linked yet. Of those, at most this many not prepared yet (each a DINOv2
    /// pass of its own): the rest wait for a later live view.
    nonisolated static let dinoPerView = 3
    nonisolated static let dinoPerViewSearching = 6
    nonisolated static let dinoNewPerView = 2
    nonisolated static let dinoNewPerViewSearching = 3
    /// When this session began (its searching pace is bounded).
    private var begun = Date()

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

    /// For the model: whether Pip knows this place from earlier visits (2 Nov, 20:34: asked "Do you
    /// know where we are", it went by a room the user had named an hour before).
    var whereabouts: String? {
        guard !stored.isEmpty else { return nil }
        if !book.linked.isEmpty {
            return "Where we are: Pip recognises this place from earlier visits (measured by the app); its remembered places and what Pip saw there can be pointed at."
        }
        return "Where we are: not recognised yet; the app is still matching this view with earlier visits (it helps when the user looks around the room slowly, at walls and furniture). Do not guess the room."
    }

    /// The stored snapshots of earlier sessions to link this one to, and how those sessions are joined
    /// in the home (their evidence is weighed together, `LinkBook.home`).
    func begin(with frames: [Keyframes.Frame], home: HomeGraph? = nil) {
        generation += 1
        begun = Date()
        firstDino = nil
        likeness = []
        lookAroundAsked = false
        stored = frames.sorted { ($0.piece?.uuidString ?? "", $0.time) < ($1.piece?.uuidString ?? "", $1.time) }
        number = Dictionary(uniqueKeysWithValues: stored.enumerated().map { ($1.id, $0) })
        book = LinkBook()
        book.home = home
        schedule = LinkSchedule()
        described = [:]
        prints = [:]
        wholes = [:]
        wholesPending = []
        wholesRead = false
        wholesMade = 0
        ownPending = []
        wholesTimer?.invalidate()
        wholesTimer = nil
        dinoStart = Date().addingTimeInterval(Self.dinoDelay)
        dino.onLog = { [weak self] line in DispatchQueue.main.async { self?.onLog?(line) } }
        let dinoViews = self.dinoViews
        dinoQueue.async { dinoViews.clear() }
        describing = []
        undescribable = []
        elsewhere = []
        let sessions = Set(stored.compactMap(\.piece)).count
        onLog?("space: \(stored.count) snapshots of \(sessions) earlier sessions to link this one to")
        describeTimer?.invalidate()
        describeTimer = nil
        readKeptCorners()
        readKeptWholes()
    }

    /// The described corners kept beside the stored snapshots, all at once (a home's 400 in well under
    /// a second); the others are described as before, a few every half second, and kept.
    private func readKeptCorners() {
        guard !stored.isEmpty else { return }
        let ids = stored.map(\.id), generation = self.generation
        cornersRead = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t0 = Date()
            var kept: [Int: (points: ViewPoints, print: ViewPrint?)] = [:]
            for (i, id) in ids.enumerated() {
                if let c = VisualMemoryStore.corners(id) { kept[i] = c }
            }
            let ms = Date().timeIntervalSince(t0) * 1000
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                for (i, c) in kept {
                    self.described[i] = c.points
                    if let p = c.print { self.prints[i] = p }
                }
                self.cornersRead = true
                self.onLog?(String(format: "space: %d of %d stored snapshots' described corners kept beside them (read in %.0f ms)", kept.count, ids.count, ms))
                self.startDescribing()
            }
        }
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
            startWholes()
        }
    }

    private func describeSome() {
        guard cornersRead else { return }
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
                if let described { VisualMemoryStore.writeCorners(frame.id, described.points, described.print) }
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
        // Said every minute also while no view is taken (standing still once linked).
        summariseIfDue()
        let t = frame.timestamp
        let dinoDue = dinoDue(at: t) && newViewpoint(frame, since: lastDinoPose)
        let cornersDue = !working && !described.isEmpty && t - lastView >= Self.interval && newViewpoint(frame, since: lastCornerPose)
        guard dinoDue || cornersDue, case .normal = frame.camera.trackingState, gate.accepts(frame) else { return }
        // DINOv2 at its own pace; the corners every 1.5 s.
        if dinoDue {
            lastDinoPose = frame.camera.transform
            considerAcrossLight(frame)
        }
        guard cornersDue else { return }
        lastView = t
        lastCornerPose = frame.camera.transform
        working = true
        liveViews += 1
        let view = Self.viewNumber(t), breaks = self.breaks, generation = self.generation
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

    /// A live view's number: the half second it was taken in, for the corners and DINOv2 alike, so
    /// views of one moment count once among the independent views a link needs.
    nonisolated static func viewNumber(_ time: TimeInterval) -> Int { Int((time * 2).rounded(.down)) }

    /// Until a session is linked, in its first `searchFor`, and while the phone is not hot: searching
    /// (the fast pace). 3 Nov, 20:36: at "serious" heat iOS slows the chips, a DINOv2 view took 847 ms
    /// instead of 293, and the fast pace only heats it further.
    private var searching: Bool {
        book.linked.isEmpty && Date().timeIntervalSince(begun) < Self.searchFor
            && ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }

    private func dinoDue(at time: TimeInterval) -> Bool {
        Self.hasModel && !dinoWorking && Date() >= dinoStart && !wholes.isEmpty
            && time - lastDino >= (searching ? Self.dinoIntervalSearching : Self.dinoInterval)
    }

    /// Once a session is linked, a view adds evidence only from a new viewpoint (25 cm or 15° from the
    /// last one): from the same place nothing new is seen, and the work only heats the phone (3 Nov,
    /// standing at a task). Walking round, the pace is the same.
    private func newViewpoint(_ frame: ARFrame, since last: simd_float4x4?) -> Bool {
        guard !book.linked.isEmpty, let last else { return true }
        let now = frame.camera.transform
        let moved = simd_distance(simd_make_float3(now.columns.3), simd_make_float3(last.columns.3))
        let turn = acos(max(-1, min(1, simd_dot(simd_normalize(simd_make_float3(now.columns.2)), simd_normalize(simd_make_float3(last.columns.2))))))
        return moved >= 0.25 || turn >= 15 * .pi / 180
    }
    private var lastCornerPose: simd_float4x4?
    private var lastDinoPose: simd_float4x4?

    /// The whole-view tokens kept beside the stored snapshots; the others are made from `dinoStart`
    /// on, and kept beside them too.
    private func readKeptWholes() {
        guard Self.hasModel, !stored.isEmpty else { return }
        let ids = stored.map(\.id), generation = self.generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var kept: [Int: [Float]] = [:]
            for (i, id) in ids.enumerated() {
                if let w = VisualMemoryStore.whole(id) { kept[i] = w }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.wholes.merge(kept) { now, _ in now }
                self.wholesRead = true
                self.wholesPending = ids.indices.filter { kept[$0] == nil }
                self.wholesBegan = Date()
                self.onLog?("space: \(kept.count) of \(ids.count) stored snapshots' whole-view tokens kept beside them"
                    + (kept.count < ids.count ? "; the other \(ids.count - kept.count) are made once, from \(Int(Self.dinoDelay)) s on" : ""))
                self.startWholes()
            }
        }
    }

    /// A snapshot this session kept: its whole-view token is made in the background, after the
    /// stored snapshots' ones, and kept beside it for the sessions after this one.
    func noteKept(_ frame: Keyframes.Frame) {
        guard Self.hasModel else { return }
        ownPending.append(frame)
        if ownPending.count > 400 { ownPending.removeFirst(ownPending.count - 400) }
        startWholes()
    }

    /// One token at a time (`wholeEvery`), from `dinoStart` on: the stored snapshots' first, the
    /// newest first, then this session's own.
    private func startWholes() {
        guard Self.hasModel, wholesTimer == nil else { return }
        wholesTimer = Timer.scheduledTimer(withTimeInterval: Self.wholeEvery, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.makeNextWhole() }
        }
    }

    private func makeNextWhole() {
        guard Date() >= dinoStart, !wholeInFlight else { return }
        let reading = !stored.isEmpty && !wholesRead
        // Those of sessions mapped elsewhere on earth wait (they may turn out to be of here).
        wholesPending.removeAll { wholes[$0] != nil }
        if !reading, let i = wholesPending.filter({ !elsewhere.contains($0) }).max(by: { stored[$0].time < stored[$1].time }) {
            wholesPending.removeAll { $0 == i }
            make(stored[i]) { [weak self] whole in
                guard let self else { return }
                self.wholes[i] = whole
                self.wholesMade += 1
                if !self.wholesPending.contains(where: { !self.elsewhere.contains($0) }) {
                    self.onLog?(String(format: "space: %d stored snapshots' whole-view tokens made in %.0f s, kept beside them from now on",
                                       self.wholesMade, Date().timeIntervalSince(self.wholesBegan)))
                }
            }
            return
        }
        if !ownPending.isEmpty {
            // This session's own snapshot: its token, and its described corners, for the sessions after it.
            let frame = ownPending.removeFirst()
            make(frame) { _ in }
            queue.async {
                if let d = Self.describe(frame) { VisualMemoryStore.writeCorners(frame.id, d.points, d.print) }
            }
            return
        }
        guard !reading else { return }
        wholesTimer?.invalidate()
        wholesTimer = nil
    }

    /// Makes a snapshot's whole-view token on the lowest priority queue, and keeps it beside it.
    private func make(_ frame: Keyframes.Frame, then done: @escaping @MainActor ([Float]) -> Void) {
        wholeInFlight = true
        let generation = self.generation, dino = self.dino
        wholesQueue.async { [weak self] in
            let whole: [Float]? = {
                guard let features = dino.model(), let jpeg = frame.jpeg(), let image = UIImage(data: jpeg)?.cgImage else { return nil }
                return try? features.describe(image).whole
            }()
            if let whole { VisualMemoryStore.writeWhole(frame.id, whole) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.wholeInFlight = false
                guard self.generation == generation, let whole else { return }
                done(whole)
            }
        }
    }

    /// A live view laid against the stored views it looks most like (DinoLink), on the DINOv2 queue:
    /// one after the other while searching, every few seconds after; what links goes into the same
    /// book as the corners' links.
    private func considerAcrossLight(_ frame: ARFrame) {
        let candidates = wholes.filter { !elsewhere.contains($0.key) }
        guard !candidates.isEmpty else { return }
        lastDino = frame.timestamp
        dinoWorking = true
        let view = Self.viewNumber(frame.timestamp)
        let perView = searching ? Self.dinoPerViewSearching : Self.dinoPerView
        let newPerView = searching ? Self.dinoNewPerViewSearching : Self.dinoNewPerView
        let breaks = self.breaks, generation = self.generation, stored = self.stored, dinoViews = self.dinoViews, dino = self.dino
        // ARKit's frame is let go as soon as it is copied: it drops frames when many are held.
        let held = HeldFrame(frame)
        dinoQueue.async { [weak self] in
            let t0 = Date()
            var links: [(Int, ViewLink)] = []
            var best: Float?
            let snap = held.frame.flatMap { FrameSnapshot(frame: $0, maxSide: 768) }
            held.frame = nil
            if let features = dino.model(), let snap, let live = Self.dinoView(snap, features: features) {
                let ranked = candidates.map { ($0.key, Self.dot($0.value, live.features.whole)) }.sorted { $0.1 > $1.1 }.prefix(perView)
                best = ranked.first?.1
                var newLeft = newPerView
                for (i, _) in ranked where stored.indices.contains(i) {
                    if !dinoViews.has(i) {
                        guard newLeft > 0 else { continue }
                        newLeft -= 1
                    }
                    guard let storedView = dinoViews.view(i, frame: stored[i], features: features) else { continue }
                    if let l = DinoLink.link(storedView, live, from: i, to: view) { links.append((i, l)) }
                }
            }
            let ms = Date().timeIntervalSince(t0) * 1000
            DispatchQueue.main.async {
                guard let self else { return }
                self.dinoWorking = false
                self.dinoMs.append(ms)
                if let best, self.generation == generation { self.noteLikeness(best) }
                guard self.breaks == breaks, self.generation == generation, !links.isEmpty else { return }
                self.dinoLinksSince += links.count
                let found = links.compactMap { i, l in self.stored[i].piece.map { (session: $0, link: l) } }
                for (session, change) in self.book.add(found) { self.report(session, change) }
            }
        }
    }

    /// How alike the live views are to the stored ones: a place that looks known and is not linked
    /// yet asks the user to look round, once.
    private func noteLikeness(_ best: Float) {
        if firstDino == nil { firstDino = Date() }
        likeness.append(best)
        if likeness.count > 6 { likeness.removeFirst(likeness.count - 6) }
        guard !lookAroundAsked, book.linked.isEmpty, let first = firstDino, Date().timeIntervalSince(first) >= Self.lookAroundAfter,
              (likeness.max() ?? 0) >= Self.lookAroundLikeness else { return }
        lookAroundAsked = true
        onLog?(String(format: "space: this place looks known (likeness %.2f) but is not linked after %.0f s: the user is asked to look round",
                      likeness.max() ?? 0, Date().timeIntervalSince(first)))
        onLookAround?()
    }

    /// The live view for DinoLink: its DINOv2 tokens and its depth, as the stored snapshots keep it.
    nonisolated private static func dinoView(_ snap: FrameSnapshot, features: ViewFeatures) -> DinoLink.View? {
        guard let described = try? features.describe(snap.image) else { return nil }
        let grid = Keyframes.depthGrid(snap)
        let depth = DepthView(width: snap.image.width, height: snap.image.height, sensorWidth: Float(snap.sensorSize.width),
                              sensorHeight: Float(snap.sensorSize.height), intrinsics: snap.intrinsics, pose: snap.cameraTransform,
                              depthW: Keyframes.depthW, depthH: Keyframes.depthH, depth: grid.map(Float.init))
        return DinoLink.View(features: described, depth: depth)
    }

    nonisolated private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for k in 0..<min(a.count, b.count) { s += a[k] * b[k] }
        return s
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
            onLog?(String(format: "space: %@ the session of %@: %d live views agree (%d matches, over %.1f m of the room; %d view links usable%@): %@",
                          change == .linked ? "linked to" : "linked again after a tracking break to", when(session), l.views, l.matches, l.extent,
                          l.usable.count, l.sessions > 1 ? String(format: "; with the evidence of %d more sessions of the home", l.sessions - 1) : "",
                          core.transform.description))
        }
        onStatus?(status())
        onChange?(session, change)
    }

    private func summariseIfDue() {
        guard Date().timeIntervalSince(lastSummary) >= Self.summaryEvery else { return }
        lastSummary = Date()
        let ms = viewMs.sorted()
        let linkedNow = book.linked.isEmpty ? "none yet" : book.linked.map { "\(when($0.key)) (\($0.value.views) views)" }.joined(separator: ", ")
        let dinoTimes = dinoMs.sorted()
        let dino = !Self.hasModel ? "no DINOv2 model"
            : String(format: "%d across light (DINOv2: %d live views, %.0f ms each, median; %d stored views described)", dinoLinksSince, dinoTimes.count,
                     dinoTimes.isEmpty ? 0 : dinoTimes[dinoTimes.count / 2], wholes.count)
        onLog?(String(format: "space: %d live views in the last minute, %d view links, %@; %.0f ms per live view (median); linked: %@; heat %@",
                      viewsSince, viewLinksSince, dino, ms.isEmpty ? 0 : ms[ms.count / 2], linkedNow, EdgeTAMFollower.heat()))
        viewsSince = 0
        viewLinksSince = 0
        dinoLinksSince = 0
        dinoMs = []
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
        // Views from the same place count again: they are in the coordinates after the break.
        lastCornerPose = nil
        lastDinoPose = nil
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

/// An ARKit frame handed to a queue, let go there once copied.
final class HeldFrame: @unchecked Sendable {
    var frame: ARFrame?
    init(_ frame: ARFrame) { self.frame = frame }
}

/// Stored views prepared for DinoLink (their DINOv2 tokens, 2 MB each, and their depth), the last
/// few used: a live view is laid against the three stored views it looks most like, and those of
/// one place come back view after view. Used on SpaceLinker's DINOv2 queue only.
final class DinoViews: @unchecked Sendable {
    private var views: [Int: DinoLink.View] = [:]
    private var order: [Int] = []
    static let keep = 24

    func view(_ i: Int, frame: Keyframes.Frame, features: ViewFeatures) -> DinoLink.View? {
        if let v = views[i] {
            order.removeAll { $0 == i }
            order.append(i)
            return v
        }
        guard let jpeg = frame.jpeg(), let image = UIImage(data: jpeg)?.cgImage, let grid = frame.depthGrid(),
              grid.count == frame.depthW * frame.depthH, let described = try? features.describe(image) else { return nil }
        let depth = DepthView(width: frame.width, height: frame.height, sensorWidth: Float(frame.sensorSize.width), sensorHeight: Float(frame.sensorSize.height),
                              intrinsics: frame.intrinsics, pose: frame.storedPose, depthW: frame.depthW, depthH: frame.depthH, depth: grid.map(Float.init))
        let v = DinoLink.View(features: described, depth: depth)
        views[i] = v
        order.append(i)
        if order.count > Self.keep { views[order.removeFirst()] = nil }
        return v
    }

    func has(_ i: Int) -> Bool { views[i] != nil }

    func clear() {
        views = [:]
        order = []
    }
}

/// Meta's DINOv2 for SpaceLinker: loaded on first use (on a background queue), and when Core ML
/// fails to, tried again 10 s later, the third time without the Neural Engine (on 2 Nov Core ML
/// could not build EdgeTAM's execution plan three times running at one start). Each outcome is said
/// in the log.
final class DinoModel: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: ViewFeatures?
    private var failures = 0
    private var nextTry = Date.distantPast
    static let maxTries = 4
    var onLog: ((String) -> Void)?

    func model() -> ViewFeatures? {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        guard failures < Self.maxTries, Date() >= nextTry,
              let url = Bundle.main.url(forResource: ViewFeatures.modelName, withExtension: "mlmodelc") else { return nil }
        let units: MLComputeUnits = failures >= 2 ? .cpuAndGPU : .all
        let t0 = Date()
        do {
            loaded = try ViewFeatures.load(from: url, computeUnits: units)
            onLog?(String(format: "space: DINOv2 loaded in %.1f s (%@)", Date().timeIntervalSince(t0), units == .all ? "Neural Engine" : "CPU and GPU"))
        } catch {
            failures += 1
            nextTry = Date().addingTimeInterval(10)
            onLog?("space: DINOv2 could not be loaded (attempt \(failures) of \(Self.maxTries)): \(error.localizedDescription)")
        }
        return loaded
    }
}
