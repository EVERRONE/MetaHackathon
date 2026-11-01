import ARKit
import Combine
import PipCore
import QuartzCore
import RealityKit

/// Owns the AR session, the anchored marks and what is drawn on them each frame. Its state is
/// here; its work by theme in ARController+Drawing (every frame), +Steering (EdgeTAM's outlines),
/// +Locks (ARKit image locks), +Room (recognising the saved room) and +Places (remembered places).
final class ARController: NSObject, ObservableObject, ARSessionDelegate {
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    let overlay = OverlayView()

    var board = AnnotationBoard()

    var marks: [Int: AnchoredMark] = [:]

    /// Each mark's ARKit anchor and where it was when the mark was placed.
    var anchors: [Int: (anchor: ARAnchor, origin: simd_float4x4)] = [:]

    /// Where ARKit says each anchor is now; the drawn outline eases towards it.
    var targetCorrections: [Int: simd_float4x4] = [:]

    /// What Pip knows about each pointed-at object over time (see `ObjectTrack`).
    var tracks: [Int: ObjectTrack] = [:]

    /// Set when tracking comes back after being lost: every object is checked again.
    var trackingRecovered = false

    /// Follows pointed-at objects in the image, so outlines stay on things that move (a remote in the hand).
    let follower = ImageFollower()

    /// EdgeTAM follows the latest pointed-at object; its mask draws that object's outline (see `steer`).
    let edgeTAM = EdgeTAMFollower()

    /// Marks whose outline EdgeTAM's mask draws now, and those of them hidden because the object
    /// moved and is not seen.
    var steered = Set<Int>()

    var steerHidden = Set<Int>()
    /// Marks riding along with the one EdgeTAM follows, at their offset from its centre (see
    /// `takeRiders`).
    var riders: [Int: (leader: Int, offset: [[simd_float3]])] = [:]
    /// Follows pointed-at objects in the image every frame; marks it draws, and those hidden
    /// because their object was lost while it moved (see PlanarFollower).
    let planar = PlanarFollower()
    var planarFollowed = Set<Int>()
    var planarHidden = Set<Int>()
    /// A followed mark's centre in the room, its velocity and the frame they are from: drawn ahead
    /// by the time from that frame to the one on screen (the tracker is a frame or two behind).
    var planarMotion: [Int: (centre: simd_float3, velocity: simd_float3, time: TimeInterval)] = [:]
    /// Each mark as first measured, on the surface it was found on (to start following it).
    var measured: [Int: AnchoredMark] = [:]

    /// A steered object's velocity and the time of the frame its outline came from.
    var steerMotion: [Int: (velocity: simd_float3, time: TimeInterval)] = [:]

    /// The mask is about 0.15–0.3 s old when drawn: a moving object is drawn where it has got to,
    /// up to this far ahead (an object that stopped is corrected by the next mask, 0.1 s later).
    static let maxLead: TimeInterval = 0.35

    /// A steered outline as drawn and as last measured. Each new mask's outline (the same number
    /// of points every time) is aligned to the drawn one, and the drawn one moves towards it over a
    /// few frames: masks come about ten times a second, and an outline that jumped to each would
    /// look restless.
    var steerShape: [Int: (shown: [simd_float3], target: [simd_float3])] = [:]

    static let steerPoints = 96

    /// How quickly a drawn outline takes up a new mask: at once for a moving object (its lead makes
    /// up for this lag), more calmly for a still one, where only the mask's noise changes it.
    static let followMoving: TimeInterval = 0.04

    static let followStill: TimeInterval = 0.12

    var lastRender: TimeInterval = 0

    /// Where each steered outline's centre was drawn, per shown camera frame (its time), for the
    /// last second: EdgeTAM's check compares it with the mask of the same frame.
    var drawnHistory: [Int: [(t: TimeInterval, p: simd_float3)]] = [:]

    /// What the user saw while a cue was drawn, kept for judging a test (see OverlayShots).
    let shots = OverlayShots()

    /// How recognising the saved room at start goes, and how well the room is being mapped.
    let relocalisation = Relocalisation()

    /// One line per running test, for the screen.
    @Published private(set) var statusLines: [String: String] = [:]

    func setStatusLine(_ key: String, _ value: String) {
        if statusLines[key] != (value.isEmpty ? nil : value) { statusLines[key] = value.isEmpty ? nil : value }
    }

    /// A moved object lies still again: measure it anew (its box in screen points).
    var onMovedObjectSettled: ((Int, CGRect) -> Void)?

    /// Outlines locked to their object in 3D through ARKit image tracking, by reference image name.
    var imageLocks: [String: ImageLock] = [:]

    static let maxImageLocks = 4

    var onLockLog: ((String) -> Void)?

    var renderSubscription: Cancellable?

    /// False while ARKit has lost the room (after leaving it): cues are hidden, not drawn wrong.
    var trackingNormal = true

    var currentOffset = 0

    var replacePending = false

    /// The room's coordinates change when ARKit recognises the saved room (by a known jump, see
    /// `realign`) and when tracking starts afresh (no relation to before). Snapshots carry the
    /// number of the coordinates they were taken in: an outline lifted from an older snapshot (a
    /// look grounded while the room was recognised) is brought along, or dropped after a fresh start.
    var coordinates = 0

    var jumps: [Int: simd_float4x4] = [:]

    /// Found in the visual memory while the saved room is still being recognised: outlined in that
    /// room's coordinates, so hidden until it is recognised, and not moved by `realign`.
    var inSavedRoomCoordinates = Set<Int>()

    // MARK: Mark numbers and remembered places (see ARController+Places.swift)

    // Mark numbers: each look gets its own block of 1000 below `foundMarkBase` (700 blocks,
    // reused in turn), objects found in the visual memory come next, remembered places last.
    static let lookBlocks = 700

    static let foundMarkBase = 800_001

    /// Mark numbers from here on are remembered places; they are never replaced by a new look.
    static let placeMarkBase = 900_001

    static func markOffset(look: Int) -> Int { ((look - 1) % lookBlocks + 1) * 1000 }

    var nextPlaceMark = ARController.placeMarkBase

    @Published var places: [Int: SpaceMemory.Place] = [:]

    /// Places from the saved map waiting for ARKit to restore their anchors.
    var pendingPlaces: [UUID: SpaceMemory.Place] = [:]

    // MARK: The AR session

    func start(initialMap: ARWorldMap? = nil) {
        // A saved room map: ARKit recognises the room again and restores the remembered places.
        awaitingFirstRelocalisation = initialMap != nil
        arView.renderOptions.insert(.disableMotionBlur)
        arView.session.delegate = self
        arView.session.run(Self.configuration(initialMap: initialMap))
        // Outlines are drawn in the same step as the camera image, so they do not lag or swim.
        renderSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in self?.renderNow() }
        follower.onSettled = { [weak self] id, box in self?.onMovedObjectSettled?(id, box) }
        edgeTAM.onStatus = { [weak self] s in self?.setStatusLine("edgetam", s) }
        edgeTAM.onLog = { [weak self] s in self?.onLockLog?(s) }
        edgeTAM.onOutline = { [weak self] id, world, velocity, time in self?.steer(id, world: world, velocity: velocity, at: time) }
        edgeTAM.onLost = { [weak self] id, moving in self?.steerLost(id, moving: moving) }
        edgeTAM.onStopped = { [weak self] id in self?.unsteer(id) }
        planar.onOutline = { [weak self] id, rings, time in self?.planarOutline(id, rings, time: time) }
        planar.onLost = { [weak self] ids, moving in self?.planarLost(ids, moving: moving) }
        planar.onLog = { [weak self] s in self?.onLockLog?(s) }
        edgeTAM.lockHeld = { [weak self] id in
            let now = CACurrentMediaTime()
            return self?.imageLocks.values.contains { $0.marks[id] != nil && $0.seen && now - $0.lastTracked < 3 } ?? false
        }
        edgeTAM.onShownCheck = { [weak self] id, mm, moving, sure in self?.lockComparison(id, mm: mm, moving: moving, sure: sure) }
        edgeTAM.drawnAt = { [weak self] id, t in
            // The shown frame with this time (frames are 1/60 s apart).
            self?.drawnHistory[id]?.min { abs($0.t - t) < abs($1.t - t) }.flatMap { abs($0.t - t) < 0.009 ? $0.p : nil }
        }
        if EdgeTAMFollower.enabled { edgeTAM.preload() }
    }

    static func configuration(initialMap: ARWorldMap?) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.initialWorldMap = initialMap
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        // Depth averaged over recent frames: less noise, so outlines sit more exactly.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        // No scene mesh: it fed only the linking of map pieces by their surfaces (removed 1 Nov),
        // and meshing with classification costs GPU and Neural Engine time EdgeTAM needs.
        return config
    }

    /// The saved room was not recognised: ARKit tries another saved room's map.
    func restart(initialMap: ARWorldMap) {
        restartHeld = 0
        awaitingFirstRelocalisation = true
        recognitionWait = Self.nextRelocaliseWait
        relocalisingSince = nil
        startAfresh(Self.configuration(initialMap: initialMap))
    }

    /// The saved room was not recognised (Pip is in another room): start fresh, so tracking works
    /// at once; the room's map waits to be linked when Pip sees it.
    func restartFresh() {
        restartHeld = 0
        awaitingFirstRelocalisation = false
        relocalisingSince = nil
        startAfresh(Self.configuration(initialMap: nil))
    }

    /// A pointed-at object on screen when tracking had to start afresh: its cue stays, and it is
    /// found again in the new session, from what the model asked for, around where it was on
    /// screen (GuideModel.findAgain). On 1 Nov every outline vanished in the middle of a test
    /// when the saved room was given up.
    struct Carried {
        let id: Int
        let spec: TargetSpec
    }
    /// Tracking started afresh with these objects on screen.
    var onStartedAfresh: (([Carried]) -> Void)?

    /// Starts tracking afresh (new coordinates, no anchors): the remembered places come back
    /// with their room's anchors; the objects with a cue on screen are found again.
    private func startAfresh(_ config: ARWorldTrackingConfiguration) {
        var carried: [Carried] = []
        if let snap = snapshot() {
            let w = Double(snap.image.width), h = Double(snap.image.height)
            for (id, box) in visibleMarkBoxes(in: snap) where id < Self.foundMarkBase {
                guard var spec = tracks[id]?.spec else { continue }
                spec.x = Double(box.midX) / w * 1000
                spec.y = Double(box.midY) / h * 1000
                carried.append(Carried(id: id, spec: spec))
            }
        }
        removeMarks { _ in true }
        places = [:]
        pendingPlaces = [:]
        board.keep(marks: Set(carried.map(\.id)))
        board.resolveDanger()
        renderNow()
        coordinates += 1
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        imagesCleared()
        if !carried.isEmpty { onStartedAfresh?(carried) }
    }

    /// Whether the camera has a pose to place outlines with (tracking normal, or running in the
    /// session's own coordinates while a saved room is recognised).
    var cameraPoseUsable: Bool {
        switch arView.session.currentFrame?.camera.trackingState {
        case .normal?, .limited(.relocalizing)?: return true
        default: return false
        }
    }

    func snapshot() -> FrameSnapshot? {
        guard var s = arView.session.currentFrame.flatMap({ FrameSnapshot(frame: $0) }) else { return nil }
        s.coordinates = coordinates
        return s
    }

    static let takenBeforeRestart = "taken before tracking restarted"

    /// A new look. The previous look's cues stay on their objects until this look shows its first
    /// cue, so the user keeps their bearings while Pip thinks, or when the answer points at nothing.
    func beginLook(markOffset: Int) {
        currentOffset = markOffset
        replacePending = true
    }

    // MARK: Marks

    /// Lifts one grounded instance into 3D. Returns how it was anchored, for the trace. `spec`
    /// (what the model asked to point at) lets Pip find the object again after drift.
    @discardableResult
    func addMark(_ inst: SegmentInstance, snapshot: FrameSnapshot, spec: TargetSpec? = nil) -> String {
        guard let carry = carry(from: snapshot.coordinates) else { return Self.takenBeforeRestart }
        // Clean, regular shapes: a raw mask outline looks hand-drawn once stroked on screen.
        guard var m = AnchoredMark(inst.regularized(), snapshot: snapshot) else { return "no outline" }
        if carry != matrix_identity_float4x4 { m = m.transformed(by: carry) }
        place(m)
        measured[m.id] = m
        if let obs = m.observation {
            tracks[m.id] = ObjectTrack(observation: obs, spec: spec)
            // Found again in the live image when its cue shows, then followed there.
            follower.start(m.id, image: snapshot.image, box: inst.boxRect)
            if EdgeTAMFollower.enabled { edgeTAM.start(markID: m.id, snapshot: snapshot, instance: inst, phrase: spec?.phrase) }
        }
        return m.method
    }

    /// A fresh measurement of an object Pip is pointing at. It is fused with the earlier ones
    /// (every view makes the position firmer), unless it shows the object has moved or Pip lost
    /// its place (after coming back): then it starts afresh from this view. The outline glides to
    /// its new place.
    @discardableResult
    func updateMark(_ inst: SegmentInstance, snapshot: FrameSnapshot, reason: ObjectTrack.Reason) -> ObjectTrack.Update? {
        // EdgeTAM or an image lock took the outline over while this was measured: theirs is newer.
        guard !steered.contains(inst.id), riders[inst.id] == nil, !planarFollowed.contains(inst.id), !lockSeen(inst.id),
              let carry = carry(from: snapshot.coordinates) else { return nil }
        guard let old = marks[inst.id], var fresh = AnchoredMark(inst.regularized(), snapshot: snapshot) else { return nil }
        if carry != matrix_identity_float4x4 { fresh = fresh.transformed(by: carry) }
        guard let obs = fresh.observation else { return nil }
        var track = tracks[inst.id] ?? ObjectTrack(observation: obs, spec: nil)
        // Earlier views were taken before ARKit's latest correction of this anchor: bring them along.
        let correction = targetCorrections[inst.id] ?? matrix_identity_float4x4
        let predicted = old.centroid
        let pixelError = snapshot.project((simd_inverse(carry) * simd_float4(predicted, 1)).xyz).map { hypot($0.x - inst.centre.x, $0.y - inst.centre.y) }
        let update = track.add(obs, correction: correction, reason: reason, predicted: predicted)
        tracks[inst.id] = track
        let placed = update.position.map { fresh.relocated(to: $0) } ?? fresh
        place(placed, glideFrom: predicted)
        follower.reanchored(inst.id)
        var result = update
        result.pixelError = pixelError.map(Double.init)
        result.correction = simd_distance(predicted, placed.centroid)
        result.method = placed.method
        return result
    }

    func place(_ m: AnchoredMark, glideFrom previous: simd_float3? = nil) {
        if let old = anchors[m.id] { arView.session.remove(anchor: old.anchor) }
        var t = matrix_identity_float4x4
        t.columns.3 = simd_float4(m.placement, 1)
        let isPlace = places[m.id] != nil
        let anchor = ARAnchor(name: isPlace ? "pip-place" : "pip-mark", transform: t)
        arView.session.add(anchor: anchor)
        anchors[m.id] = (anchor, t)
        targetCorrections[m.id] = nil
        var m = m
        if let previous { m.glide = previous - m.centroid }
        marks[m.id] = m
        // A remembered place keeps its new, measured position: on its new anchor, in storage.
        if isPlace, var p = places[m.id] {
            let inverse = simd_inverse(t)
            p.anchorID = anchor.identifier
            p.pose = Self.values(t)
            p.outline = m.polygons.map { ring in ring.map { (inverse * simd_float4($0 - m.glide, 1)).xyz } }
            places[m.id] = p
            // Stored just now: the copy ARKit restored at start is out of date.
            restoredPlaces.removeAll { $0.id == p.id }
            onPlaceMoved?(p)
        }
    }

    func removeMarks(where shouldRemove: (Int) -> Bool) {
        let removed = Set(marks.keys.filter(shouldRemove))
        for id in removed {
            if let a = anchors[id] { arView.session.remove(anchor: a.anchor) }
            anchors[id] = nil
            marks[id] = nil
            tracks[id] = nil
            targetCorrections[id] = nil
            follower.stop(id)
            steered.remove(id)
            steerHidden.remove(id)
            steerMotion[id] = nil
            steerShape[id] = nil
            drawnHistory[id] = nil
            lockDisagreements[id] = nil
            inSavedRoomCoordinates.remove(id)
            riders[id] = nil
            planarFollowed.remove(id)
            planarHidden.remove(id)
            planarMotion[id] = nil
            measured[id] = nil
        }
        if !planar.isEmpty { planar.stop(removed) }
        // Riding along with a mark that is gone: back on room anchors.
        let orphans = riders.filter { marks[$0.value.leader] == nil }.map(\.key)
        orphans.forEach { riders[$0] = nil }
        reanchor(orphans)
        // A lock keeps the marks still there; one with none left goes (its picture stays in
        // ARKit's set until the next run, see `reconfigureImages`).
        for (name, var lock) in imageLocks {
            lock.marks = lock.marks.filter { marks[$0.key] != nil }
            imageLocks[name] = lock.marks.isEmpty ? nil : lock
        }
    }

    // MARK: Image locks (see ARController+Locks.swift)

    /// Recent comparisons of a lock's outline with EdgeTAM's mask of the same frame, for still
    /// objects: true where they disagreed.
    var lockDisagreements: [Int: [Bool]] = [:]

    var lastImageSet: Set<String> = []
    /// When the session was last run with other reference images, and whether a run waits (see
    /// `reconfigureImages`).
    var lastImageRun: TimeInterval = 0
    var imageRunScheduled = false
    var lockSerial = 0

    // MARK: Measuring again

    /// After Pip found one object again and saw it had drifted, the other objects pointed at in
    /// the same room have drifted the same way: they move by the same offset until they are
    /// measured themselves.
    func shiftNeighbours(of id: Int, by offset: simd_float3) {
        guard let centre = marks[id]?.centroid, simd_length(offset) > 0.01, simd_length(offset) < 1 else { return }
        for (other, m) in marks where other != id && other < Self.placeMarkBase && simd_distance(m.centroid, centre) < 4 {
            // Only objects not measured since the drift showed up, and not held by EdgeTAM or a lock.
            guard !steered.contains(other), riders[other] == nil, !planarFollowed.contains(other), !lockSeen(other),
                  var track = tracks[other], track.needsCheck || track.isAway else { continue }
            let before = m.centroid
            track.align(targetCorrections[other] ?? matrix_identity_float4x4)
            place(m.relocated(to: m.centroid + offset), glideFrom: before)
            track.shifted(by: offset)
            tracks[other] = track
        }
    }

    /// Which objects to measure again now, most urgent first: one that came back into view
    /// (Pip may have drifted while it was away), one seen from a new enough place to triangulate,
    /// and during a task a regular check whether it moved.
    func remeasureCandidates(in snapshot: FrameSnapshot, taskActive: Bool) -> [(id: Int, box: CGRect, reason: ObjectTrack.Reason)] {
        let now = CACurrentMediaTime()
        let camera = simd_make_float3(snapshot.cameraTransform.columns.3)
        let recovered = trackingRecovered
        trackingRecovered = false
        var out: [(Int, CGRect, ObjectTrack.Reason, Int)] = []
        // Remembered places too: one brought back from storage is found again when Pip points at it.
        // Once an outline is locked to its object, only the lock (or EdgeTAM) moves it.
        let locked = Set(imageLocks.values.filter(\.seen).flatMap(\.marks.keys)).union(steered).union(riders.keys).union(planarFollowed)
        for (id, box) in visibleMarkBoxes(in: snapshot) where !locked.contains(id) {
            guard var track = tracks[id], let m = marks[id] else { continue }
            if recovered { track.needsCheck = true; tracks[id] = track }
            guard let reason = track.reason(now: now, camera: camera, centre: m.centroid, taskActive: taskActive) else { continue }
            out.append((id, box, reason, reason.priority))
        }
        return out.sorted { $0.3 > $1.3 }.prefix(3).map { ($0.0, $0.1, $0.2) }
    }

    /// What the model asked to point at for a mark, placed where the mark is in this snapshot.
    func spec(for id: Int, in snapshot: FrameSnapshot, box: CGRect) -> TargetSpec? {
        guard var spec = tracks[id]?.spec else { return nil }
        spec.x = Double(box.midX / CGFloat(snapshot.image.width) * 1000)
        spec.y = Double(box.midY / CGFloat(snapshot.image.height) * 1000)
        return spec
    }

    /// A measurement was tried but the object was not found where expected.
    func measureFailed(_ id: Int) {
        tracks[id]?.failed(now: CACurrentMediaTime())
    }

    /// Marks with a cue on screen, and their outline's box in the snapshot's pixels.
    func visibleMarkBoxes(in snapshot: FrameSnapshot) -> [(id: Int, box: CGRect)] {
        let shown = Set(board.annotations.flatMap { $0.cue.marks })
        let bounds = CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height)
        return shown.compactMap { id -> (Int, CGRect)? in
            guard let m = marks[id] else { return nil }
            let pts = m.polygons.flatMap { $0 }.compactMap(snapshot.project)
            guard pts.count >= 3 else { return nil }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            return bounds.intersects(box) && box.width > 4 && box.height > 4 ? (id, box) : nil
        }.sorted { $0.0 < $1.0 }
    }

    // MARK: Cues

    func show(_ cue: Cue) {
        if replacePending, cue.isDrawn {
            // The new answer points somewhere: earlier looks' and found objects' cues and marks give way.
            replacePending = false
            board.show(.clear, at: CACurrentMediaTime())
            board.resolveDanger()
            let current = currentOffset..<(currentOffset + 1000)
            removeMarks { $0 < Self.placeMarkBase && !current.contains($0) }
        }
        board.show(cue, at: CACurrentMediaTime())
        renderNow()
    }

    /// A step was seen done: its pointing turns into a short green check.
    func markVerified() {
        let now = CACurrentMediaTime()
        let shown = board.annotations.filter { $0.lifetime == .untilVerified }.flatMap { $0.cue.marks }
        for m in Set(shown) where marks[m] != nil { board.show(.verified(mark: m), at: now) }
        renderNow()
    }

    func clearCues() {
        board.show(.clear, at: CACurrentMediaTime())
        board.resolveDanger()
        removeMarks { $0 < Self.placeMarkBase }
        renderNow()
    }

    /// Whether a measured object has a cue on screen (re-measuring has work to do).
    var hasPointedMarks: Bool {
        board.annotations.contains { $0.cue.marks.contains { tracks[$0] != nil && marks[$0] != nil } }
    }

    // MARK: ARSessionDelegate

    /// Called for every camera frame (reading mode uses it to take pages).
    var onFrame: ((ARFrame) -> Void)?

    /// ARKit's light estimates of the last few seconds (intensity, colour temperature).
    var lightSamples: [(intensity: Double, temperature: Double)] = []

    /// The light now: the median of the last few seconds of ARKit's estimates.
    var currentLight: MapLight? {
        guard lightSamples.count >= 10 else { return nil }
        let i = lightSamples.map(\.intensity).sorted(), t = lightSamples.map(\.temperature).sorted()
        return MapLight(intensity: i[i.count / 2], temperature: t[t.count / 2])
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        onFrame?(frame)
        if let light = frame.lightEstimate, Int(frame.timestamp * 60) % 6 == 0 {
            lightSamples.append((Double(light.ambientIntensity), Double(light.ambientColorTemperature)))
            if lightSamples.count > 50 { lightSamples.removeFirst(lightSamples.count - 50) }
        }
        if awaitingFirstRelocalisation, case .limited(.relocalizing) = frame.camera.trackingState {
            lastRecognisingCamera = frame.camera.transform
            lastRecognisingTime = frame.timestamp
        }
        followObjects(frame)
        planar.frame(frame)
        edgeTAM.frame(frame, viewSize: arView.bounds.size, markExists: edgeTAM.markID.map { marks[$0] != nil } ?? false)
        if case .normal = frame.camera.trackingState, (frame.lightEstimate?.ambientIntensity ?? 1000) >= 80 {} else {
            lastTrackingTrouble = CACurrentMediaTime()
        }
        relocalisation.frame(frame, awaitingRecognition: awaitingFirstRelocalisation)
        // ARKit moves anchors when it corrects its map (loop closure, relocalisation); the drawn
        // outline eases towards the new place in `renderNow`.
        if !anchors.isEmpty {
            let current = Dictionary(frame.anchors.map { ($0.identifier, $0.transform) }, uniquingKeysWith: { a, _ in a })
            for (id, entry) in anchors {
                guard let now = current[entry.anchor.identifier] else { continue }
                targetCorrections[id] = now * simd_inverse(entry.origin)
            }
        }
    }

    func session(_ session: ARSession, didAdd added: [ARAnchor]) {
        for anchor in added { restorePlace(anchor) }
        updateLocks(added)
    }

    func session(_ session: ARSession, didUpdate updated: [ARAnchor]) {
        updateLocks(updated)
    }

    // MARK: Recognising the saved room (see ARController+Room.swift)

    var recognitionExtended: TimeInterval = 0
    /// How long trying the next saved room (a fresh start) has waited for questions being answered.
    var restartHeld: TimeInterval = 0
    /// Whether a question is being answered: its frame and the outlines grounded on it are in this
    /// session's coordinates, which a fresh start would throw away (1 Nov: two questions in the
    /// first 45 s straddled a switch to the next saved room, and pointed at nothing).
    var restartHold: (() -> Bool)?

    /// The camera while ARKit was still recognising the room: its pose just before and just after
    /// recognition shows how far the room's coordinates moved.
    var lastRecognisingCamera: simd_float4x4?

    var lastRecognisingTime: TimeInterval = 0

    var checkScheduledFor: Date?

    var recognitionWait = ARController.firstRelocaliseWait

    var relocalisingSince: Date?

    var awaitingFirstRelocalisation = false

    /// ARKit lost the room since tracking was last normal (`trackingNormal` may already be true
    /// again, when Pip gave up waiting and shows the cues anyway).
    var trackingLost = false

    /// The saved room was not recognised at start.
    var onRelocaliseGaveUp: (() -> Void)?

    /// The saved room was recognised at start.
    var onRecognised: (() -> Void)?

    // MARK: Remembered places (see ARController+Places.swift)

    /// Places ARKit restored from the saved map, with their pose now known (to store once).
    var restoredPlaces: [SpaceMemory.Place] = []

    /// A remembered place was measured again: its new pose and outline, to store.
    var onPlaceMoved: ((SpaceMemory.Place) -> Void)?

    /// When tracking was last limited, lost or in the dark.
    var lastTrackingTrouble: CFTimeInterval = 0
}
