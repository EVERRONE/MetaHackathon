import ARKit
import Combine
import PipCore
import QuartzCore
import RealityKit

/// Owns the AR session, the anchored marks and what is drawn on them each frame.
final class ARController: NSObject, ObservableObject, ARSessionDelegate {
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    let overlay = OverlayView()

    private(set) var board = AnnotationBoard()
    private var marks: [Int: AnchoredMark] = [:]
    /// Each mark's ARKit anchor and where it was when the mark was placed.
    private var anchors: [Int: (anchor: ARAnchor, origin: simd_float4x4)] = [:]
    /// Where ARKit says each anchor is now; the drawn outline eases towards it.
    private var targetCorrections: [Int: simd_float4x4] = [:]
    /// What Pip knows about each pointed-at object over time (see `ObjectTrack`).
    private(set) var tracks: [Int: ObjectTrack] = [:]
    /// Set when tracking comes back after being lost: every object is checked again.
    private var trackingRecovered = false
    /// Follows pointed-at objects in the image, so outlines stay on things that move (a remote in the hand).
    let follower = ImageFollower()
    /// EdgeTAM follows the latest pointed-at object; its mask draws that object's outline (see `steer`).
    let edgeSpike = EdgeTAMSpike()
    /// Marks whose outline EdgeTAM's mask draws now, and those of them hidden because the object
    /// moved and is not seen.
    private var steered = Set<Int>()
    private var steerHidden = Set<Int>()
    /// A steered object's velocity and the time of the frame its outline came from.
    private var steerMotion: [Int: (velocity: simd_float3, time: TimeInterval)] = [:]
    /// The mask is about 0.15–0.3 s old when drawn: a moving object is drawn where it has got to,
    /// up to this far ahead (an object that stopped is corrected by the next mask, 0.1 s later).
    static let maxLead: TimeInterval = 0.35
    /// A steered outline as drawn and as last measured. Each new mask's outline (the same number
    /// of points every time) is aligned to the drawn one, and the drawn one moves towards it over a
    /// few frames: masks come about ten times a second, and an outline that jumped to each would
    /// look restless.
    private var steerShape: [Int: (shown: [simd_float3], target: [simd_float3])] = [:]
    static let steerPoints = 96
    /// How quickly a drawn outline takes up a new mask: at once for a moving object (its lead makes
    /// up for this lag), more calmly for a still one, where only the mask's noise changes it.
    static let followMoving: TimeInterval = 0.04
    static let followStill: TimeInterval = 0.12
    private var lastRender: TimeInterval = 0
    /// Where each steered outline's centre was drawn, per shown camera frame (its time), for the
    /// last second: EdgeTAM's check compares it with the mask of the same frame.
    private var drawnHistory: [Int: [(t: TimeInterval, p: simd_float3)]] = [:]
    /// What the user saw while a cue was drawn, kept for judging a test (see OverlayShots).
    private let shots = OverlayShots()
    /// How recognising the saved room at start goes, and how well the room is being mapped.
    let relocalisation = Relocalisation()
    /// One line per running test, for the screen.
    @Published private(set) var spikeStatus: [String: String] = [:]

    func setSpikeStatus(_ key: String, _ value: String) {
        if spikeStatus[key] != (value.isEmpty ? nil : value) { spikeStatus[key] = value.isEmpty ? nil : value }
    }
    /// A moved object lies still again: measure it anew (its box in screen points).
    var onMovedObjectSettled: ((Int, CGRect) -> Void)?
    /// Outlines locked to their object in 3D through ARKit image tracking, by reference image name.
    private var imageLocks: [String: ImageLock] = [:]
    static let maxImageLocks = 4
    var onLockLog: ((String) -> Void)?
    private var renderSubscription: Cancellable?
    /// False while ARKit has lost the room (after leaving it): cues are hidden, not drawn wrong.
    private(set) var trackingNormal = true
    private var currentOffset = 0
    private var replacePending = false

    // MARK: Remembered places

    // Mark numbers: each look gets its own block of 1000 below `foundMarkBase` (700 blocks,
    // reused in turn), objects found in the visual memory come next, remembered places last.
    static let lookBlocks = 700
    static let foundMarkBase = 800_001
    /// Mark numbers from here on are remembered places; they are never replaced by a new look.
    static let placeMarkBase = 900_001

    static func markOffset(look: Int) -> Int { ((look - 1) % lookBlocks + 1) * 1000 }

    private var nextPlaceMark = ARController.placeMarkBase
    @Published private(set) var places: [Int: SpaceMemory.Place] = [:]
    /// Places from the saved map waiting for ARKit to restore their anchors.
    private var pendingPlaces: [UUID: SpaceMemory.Place] = [:]

    func start(initialMap: ARWorldMap? = nil) {
        // A saved room map: ARKit recognises the room again and restores the remembered places.
        awaitingFirstRelocalisation = initialMap != nil
        arView.renderOptions.insert(.disableMotionBlur)
        arView.session.delegate = self
        arView.session.run(Self.configuration(initialMap: initialMap))
        // Outlines are drawn in the same step as the camera image, so they do not lag or swim.
        renderSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in self?.renderNow() }
        follower.onSettled = { [weak self] id, box in self?.onMovedObjectSettled?(id, box) }
        edgeSpike.onStatus = { [weak self] s in self?.setSpikeStatus("edgetam", s) }
        edgeSpike.onLog = { [weak self] s in self?.onLockLog?(s) }
        edgeSpike.onOutline = { [weak self] id, world, velocity, time in self?.steer(id, world: world, velocity: velocity, at: time) }
        edgeSpike.onLost = { [weak self] id, moving in self?.steerLost(id, moving: moving) }
        edgeSpike.lockHeld = { [weak self] id in
            let now = CACurrentMediaTime()
            return self?.imageLocks.values.contains { $0.markID == id && $0.seen && now - $0.lastTracked < 3 } ?? false
        }
        edgeSpike.onShownCheck = { [weak self] id, mm, moving in self?.lockComparison(id, mm: mm, moving: moving) }
        edgeSpike.drawnAt = { [weak self] id, t in
            // The shown frame with this time (frames are 1/60 s apart).
            self?.drawnHistory[id]?.min { abs($0.t - t) < abs($1.t - t) }.flatMap { abs($0.t - t) < 0.009 ? $0.p : nil }
        }
        if EdgeTAMSpike.enabled { edgeSpike.preload() }
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
        // The room's surfaces as a mesh, with what each surface is (wall, floor, table, seat…):
        // Pip's 3D map of the home is built from it.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        return config
    }

    /// Until ARKit tracks normally (a fresh session takes about a second), at most `seconds`.
    @MainActor
    func waitForTracking(seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let state = arView.session.currentFrame?.camera.trackingState, case .normal = state { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The saved room was not recognised: ARKit tries another saved room's map.
    func restart(initialMap: ARWorldMap) {
        awaitingFirstRelocalisation = true
        recognitionWait = Self.nextRelocaliseWait
        relocalisingSince = nil
        removeMarks { _ in true }
        places = [:]
        pendingPlaces = [:]
        clearCues()
        arView.session.run(Self.configuration(initialMap: initialMap), options: [.resetTracking, .removeExistingAnchors])
    }

    /// The saved room was not recognised (Pip is in another room): start fresh, so tracking works
    /// at once; the room's map waits to be linked when Pip sees it.
    func restartFresh() {
        awaitingFirstRelocalisation = false
        relocalisingSince = nil
        removeMarks { _ in true }
        places = [:]
        pendingPlaces = [:]
        clearCues()
        arView.session.run(Self.configuration(initialMap: nil), options: [.resetTracking, .removeExistingAnchors])
    }

    /// The room's surfaces ARKit has meshed so far (world space), averaged per `size` cube, with
    /// the mesh's normals and ARKit's class of each surface; only within `radius` of `centre`
    /// when given.
    func meshSurface(near centre: simd_float3? = nil, radius: Float = 0, size: Float = 0.025) -> (points: [simd_float3], normals: [simd_float3], classes: [UInt8]) {
        let raw = meshRaw(near: centre, radius: radius)
        return VoxelIndex.average(raw.points, normals: raw.normals, classes: raw.classes, size: size)
    }

    /// Every mesh vertex (world space) with its normal and class: copied out of ARKit's buffers
    /// here, averaged elsewhere (off the main thread when saving).
    func meshRaw(near centre: simd_float3? = nil, radius: Float = 0) -> (points: [simd_float3], normals: [simd_float3], classes: [UInt8]) {
        let meshes = (arView.session.currentFrame?.anchors ?? []).compactMap { $0 as? ARMeshAnchor }
        var points: [simd_float3] = [], normals: [simd_float3] = [], classes: [UInt8] = []
        for mesh in meshes {
            // Mesh anchors cover about a metre each: skip those clearly out of reach.
            if let centre, simd_distance(mesh.transform.columns.3.xyz, centre) > radius + 1.5 { continue }
            let g = mesh.geometry
            let t = mesh.transform
            let vertexBase = g.vertices.buffer.contents().advanced(by: g.vertices.offset)
            let normalBase = g.normals.buffer.contents().advanced(by: g.normals.offset)
            // Each vertex takes the class of a face it belongs to.
            var vertexClass = [UInt8](repeating: 0, count: g.vertices.count)
            if let cls = g.classification, g.faces.bytesPerIndex == 4 {
                let faceBase = g.faces.buffer.contents()
                let clsBase = cls.buffer.contents().advanced(by: cls.offset)
                for f in 0..<g.faces.count {
                    let c = clsBase.advanced(by: f * cls.stride).assumingMemoryBound(to: UInt8.self).pointee
                    let idx = faceBase.advanced(by: f * g.faces.indexCountPerPrimitive * 4).assumingMemoryBound(to: UInt32.self)
                    for k in 0..<g.faces.indexCountPerPrimitive where Int(idx[k]) < vertexClass.count { vertexClass[Int(idx[k])] = c }
                }
            }
            for i in 0..<g.vertices.count {
                let v = vertexBase.advanced(by: i * g.vertices.stride).assumingMemoryBound(to: Float.self)
                let p = (t * simd_float4(v[0], v[1], v[2], 1)).xyz
                if let centre, simd_distance(p, centre) > radius { continue }
                let n = normalBase.advanced(by: i * g.normals.stride).assumingMemoryBound(to: Float.self)
                points.append(p)
                normals.append((t * simd_float4(n[0], n[1], n[2], 0)).xyz)
                classes.append(vertexClass[i])
            }
        }
        return (points, normals, classes)
    }

    /// The meshed surfaces as points only (for fitting a live view).
    func meshPoints(near centre: simd_float3? = nil, radius: Float = 0) -> [simd_float3] {
        meshSurface(near: centre, radius: radius, size: 0.04).points
    }

    func snapshot() -> FrameSnapshot? {
        arView.session.currentFrame.flatMap { FrameSnapshot(frame: $0) }
    }

    /// A new look. The previous look's cues stay on their objects until this look shows its first
    /// cue, so the user keeps their bearings while Pip thinks, or when the answer points at nothing.
    func beginLook(markOffset: Int) {
        currentOffset = markOffset
        replacePending = true
    }

    /// Lifts one grounded instance into 3D. Returns how it was anchored, for the trace. `spec`
    /// (what the model asked to point at) lets Pip find the object again after drift.
    @discardableResult
    func addMark(_ inst: SegmentInstance, snapshot: FrameSnapshot, spec: TargetSpec? = nil) -> String {
        // Clean, regular shapes: a raw mask outline looks hand-drawn once stroked on screen.
        guard let m = AnchoredMark(inst.regularized(), snapshot: snapshot) else { return "no outline" }
        place(m)
        if let obs = m.observation {
            tracks[m.id] = ObjectTrack(observation: obs, spec: spec)
            // Found again in the live image when its cue shows, then followed there.
            follower.start(m.id, image: snapshot.image, box: inst.boxRect)
            if EdgeTAMSpike.enabled { edgeSpike.start(markID: m.id, snapshot: snapshot, instance: inst, phrase: spec?.phrase) }
        }
        return m.method
    }

    /// A fresh measurement of an object Pip is pointing at. It is fused with the earlier ones
    /// (every view makes the position firmer), unless it shows the object has moved or Pip lost
    /// its place (after coming back): then it starts afresh from this view. The outline glides to
    /// its new place.
    @discardableResult
    func updateMark(_ inst: SegmentInstance, snapshot: FrameSnapshot, reason: ObjectTrack.Reason) -> ObjectTrack.Update? {
        guard let old = marks[inst.id], let fresh = AnchoredMark(inst.regularized(), snapshot: snapshot), let obs = fresh.observation else { return nil }
        var track = tracks[inst.id] ?? ObjectTrack(observation: obs, spec: nil)
        // Earlier views were taken before ARKit's latest correction of this anchor: bring them along.
        let correction = targetCorrections[inst.id] ?? matrix_identity_float4x4
        let predicted = old.centroid
        let pixelError = snapshot.project(predicted).map { hypot($0.x - inst.centre.x, $0.y - inst.centre.y) }
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

    private func place(_ m: AnchoredMark, glideFrom previous: simd_float3? = nil) {
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

    private func removeMarks(where shouldRemove: (Int) -> Bool) {
        for id in marks.keys where shouldRemove(id) {
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
        }
        let gone = imageLocks.filter { marks[$0.value.markID] == nil }.map(\.key)
        if !gone.isEmpty {
            for name in gone { imageLocks[name] = nil }
            reconfigureImages()
        }
    }

    // MARK: Locking outlines to their object (ARKit image tracking)

    /// Recent comparisons of a lock's outline with EdgeTAM's mask of the same frame, for still
    /// objects: true where they disagreed.
    private var lockDisagreements: [Int: [Bool]] = [:]

    /// EdgeTAM measured the object on a frame where the lock drew its outline `mm` away. ARKit's
    /// image tracking can align a face with repeating parts (a keyboard, a remote's grid of buttons)
    /// one key or button off and hold it there (1 Nov: the reticle on alt instead of the Windows
    /// key, on ZONE SELECT instead of POWER, 21 mm off for seconds). EdgeTAM follows the target
    /// itself from SAM's mask: when the two disagree by more than half the target's size (at least
    /// 6 mm) on most of the recent still frames, the lock is let go and EdgeTAM draws the outline.
    func lockComparison(_ id: Int, mm: Double, moving: Bool) {
        guard !moving, let lock = imageLocks.values.first(where: { $0.markID == id && $0.seen && $0.tracked }), let m = marks[id] else { return }
        let pts = m.polygons.flatMap { $0 }
        guard let first = pts.first else { return }
        var lo = first, hi = first
        for p in pts { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let size = Double(simd_reduce_max(hi - lo)) * 1000
        let limit = max(6, 0.5 * size)
        var recent = lockDisagreements[id] ?? []
        recent.append(mm > limit)
        if recent.count > 8 { recent.removeFirst(recent.count - 8) }
        lockDisagreements[id] = recent
        guard recent.count >= 5, recent.filter({ $0 }).count >= 5 else { return }
        imageLocks[lock.name] = nil
        lockDisagreements[id] = nil
        onLockLog?(String(format: "lock: mark %d let go: its face was aligned %.0f mm off the target (EdgeTAM agrees with itself, not with the lock); EdgeTAM draws it now", id % 1000, mm))
        reconfigureImages()
    }

    /// Hands ARKit a reference image of the object a mark is on; once ARKit has checked it has
    /// enough texture, it follows the object and the mark goes with it.
    func lock(markID: Int, image: CGImage, physicalWidth: CGFloat, local: [[simd_float3]]) {
        guard marks[markID] != nil, physicalWidth > 0.01 else { return }
        let reference = ARReferenceImage(image, orientation: .up, physicalWidth: physicalWidth)
        reference.name = "pip-lock-\(markID)"
        reference.validate { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.onLockLog?("lock: mark \(markID % 1000) not trackable as an image (\(error.localizedDescription)); following in the image instead")
                    return
                }
                guard self.marks[markID] != nil else { return }
                // At most a few at once: the oldest lock gives way (by age: mark numbers wrap).
                if self.imageLocks.count >= Self.maxImageLocks, let oldest = self.imageLocks.values.min(by: { $0.created < $1.created }) {
                    self.imageLocks[oldest.name] = nil
                    // ARKit held that outline, not a room anchor: put it back on one where it is now.
                    if oldest.seen, let m = self.marks[oldest.markID] { self.place(m) }
                }
                self.imageLocks[reference.name!] = ImageLock(markID: markID, reference: reference, local: local)
                self.onLockLog?(String(format: "lock: mark %d locked to its object (%.0f mm wide reference)", markID % 1000, physicalWidth * 1000))
                self.reconfigureImages()
            }
        }
    }

    private var lastImageSet: Set<String> = []

    /// Runs the session again with the current reference images (no reset: tracking, anchors and
    /// the room map go on). Skipped while ARKit is still recognising a saved room.
    private func reconfigureImages() {
        let names = Set(imageLocks.keys)
        guard names != lastImageSet, !awaitingFirstRelocalisation else { return }
        lastImageSet = names
        let config = Self.configuration(initialMap: nil)
        config.detectionImages = Set(imageLocks.values.map(\.reference))
        config.maximumNumberOfTrackedImages = min(Self.maxImageLocks, imageLocks.count)
        config.automaticImageScaleEstimationEnabled = true
        arView.session.run(config)
    }

    /// ARKit moved a locked object's image: its mark follows, in 3D.
    private func updateLocks(_ changed: [ARAnchor]) {
        for case let anchor as ARImageAnchor in changed {
            guard let name = anchor.referenceImage.name, var lock = imageLocks[name], marks[lock.markID] != nil else { continue }
            let id = lock.markID
            if !lock.seen {
                // From now on ARKit's image pose holds the mark, not the room anchor.
                lock.seen = true
                if let a = anchors[id] { arView.session.remove(anchor: a.anchor) }
                anchors[id] = nil
                targetCorrections[id] = nil
                follower.stop(id)
                onLockLog?("lock: mark \(id % 1000) found on its object; following it in 3D")
            }
            lock.tracked = anchor.isTracked
            if anchor.isTracked { lock.lastTracked = CACurrentMediaTime() }
            imageLocks[name] = lock
            guard anchor.isTracked else { continue }
            let s = Float(anchor.estimatedScaleFactor)
            let t = anchor.transform
            let world = lock.local.map { ring in ring.map { (t * simd_float4($0 * s, 1)).xyz } }
            marks[id] = AnchoredMark(id: id, world: world)
        }
    }

    /// EdgeTAM saw the object: its outline is the mask's, in the room. A flat face that ARKit's image
    /// tracking holds is more exact (under a millimetre to 1.5 mm): there the lock keeps the outline.
    func steer(_ id: Int, world: [[simd_float3]], velocity: simd_float3 = .zero, at time: TimeInterval = CACurrentMediaTime()) {
        guard marks[id] != nil else { return }
        if imageLocks.values.contains(where: { $0.markID == id && $0.seen && $0.tracked }) { return }
        if !steered.contains(id) {
            // From now on EdgeTAM holds the outline, not the room anchor or the box tracker.
            steered.insert(id)
            if let a = anchors[id] { arView.session.remove(anchor: a.anchor) }
            anchors[id] = nil
            targetCorrections[id] = nil
            follower.stop(id)
            onLockLog?("edgetam: mark \(id % 1000) is drawn from EdgeTAM's mask")
        }
        steerHidden.remove(id)
        guard let ring = world.first, ring.count >= 3 else { return }
        var target = Contour.resample(ring, count: Self.steerPoints)
        // From the outline drawn so far (the first time: SAM's), unless the object was found again
        // somewhere else: then it is drawn there at once rather than sliding across the room.
        if let drawn = steerShape[id]?.shown ?? marks[id]?.polygons.first.map({ Contour.resample($0, count: Self.steerPoints) }) {
            target = Contour.aligned(target, to: drawn, eitherWay: steerShape[id] == nil)
            let jumped = simd_distance(Contour.centroid(target), Contour.centroid(drawn)) > 0.25
            steerShape[id] = (jumped ? target : drawn, target)
        } else {
            steerShape[id] = (target, target)
        }
        var m = AnchoredMark(id: id, world: [steerShape[id]!.shown])
        m.lead = marks[id]?.lead ?? .zero
        marks[id] = m
        steerMotion[id] = (velocity, time)
    }

    /// EdgeTAM does not see the object: if it was moving, its outline waits hidden until it is seen
    /// again; if not, it stays where the object was (out of view, or covered for a moment).
    func steerLost(_ id: Int, moving: Bool) {
        guard steered.contains(id), moving else { return }
        steerHidden.insert(id)
    }

    /// ARKit recognised the saved room and moved the room's coordinates by `jump` (the camera did
    /// not move in that instant: its pose before and after gives the jump). Outlines placed before
    /// go along: those ARKit did not move with their anchors are moved here, steered ones too. They
    /// are also measured again (`trackingRecovered`), as after any loss of tracking.
    private func realign(by jump: simd_float4x4) {
        let shift = simd_length(simd_float3(jump.columns.3.x, jump.columns.3.y, jump.columns.3.z))
        let angle = acos(min(1, max(-1, (jump.columns.0.x + jump.columns.1.y + jump.columns.2.z - 1) / 2))) * 180 / .pi
        guard shift > 0.02 || angle > 2 else { return }
        let current = Dictionary((arView.session.currentFrame?.anchors ?? []).map { ($0.identifier, $0.transform) }, uniquingKeysWith: { a, _ in a })
        var movedByARKit = 0, movedHere = 0
        for (id, m) in marks where id < Self.placeMarkBase {
            if imageLocks.values.contains(where: { $0.markID == id && $0.seen }) { continue }
            if let shape = steerShape[id] {
                func move(_ p: simd_float3) -> simd_float3 { let q = jump * simd_float4(p, 1); return simd_float3(q.x, q.y, q.z) }
                steerShape[id] = (shape.shown.map(move), shape.target.map(move))
                var moved = AnchoredMark(id: id, world: [steerShape[id]!.shown])
                moved.lead = m.lead
                marks[id] = moved
                drawnHistory[id] = nil
                movedHere += 1
                continue
            }
            if let entry = anchors[id], let now = current[entry.anchor.identifier] {
                let expected = jump * entry.origin
                let nowP = simd_float3(now.columns.3.x, now.columns.3.y, now.columns.3.z)
                let expectedP = simd_float3(expected.columns.3.x, expected.columns.3.y, expected.columns.3.z)
                let originP = simd_float3(entry.origin.columns.3.x, entry.origin.columns.3.y, entry.origin.columns.3.z)
                if simd_distance(nowP, expectedP) < simd_distance(nowP, originP) {
                    movedByARKit += 1
                    continue
                }
            }
            var moved = m.transformed(by: jump)
            moved.correction = matrix_identity_float4x4
            moved.glide = .zero
            place(moved)
            movedHere += 1
        }
        edgeSpike.coordinatesMoved()
        if !tracks.isEmpty { trackingRecovered = true }
        onLockLog?(String(format: "map: recognised; the room's coordinates moved %.0f cm and %.0f°; %d outlines moved here, %d by ARKit", shift * 100, angle, movedHere, movedByARKit))
    }

    /// After Pip found one object again and saw it had drifted, the other objects pointed at in
    /// the same room have drifted the same way: they move by the same offset until they are
    /// measured themselves.
    func shiftNeighbours(of id: Int, by offset: simd_float3) {
        guard let centre = marks[id]?.centroid, simd_length(offset) > 0.01, simd_length(offset) < 1 else { return }
        for (other, m) in marks where other != id && other < Self.placeMarkBase && simd_distance(m.centroid, centre) < 4 {
            // Only objects not measured since the drift showed up.
            guard var track = tracks[other], track.needsCheck || track.isAway else { continue }
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
        let locked = Set(imageLocks.values.filter(\.seen).map(\.markID)).union(steered)
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

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        onFrame?(frame)
        if awaitingFirstRelocalisation, case .limited(.relocalizing) = frame.camera.trackingState { lastRecognisingCamera = frame.camera.transform }
        followObjects(frame)
        edgeSpike.frame(frame, viewSize: arView.bounds.size, markExists: edgeSpike.markID.map { marks[$0] != nil } ?? false)
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

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            relocalisingSince = nil
            let wasFirstRelocalisation = awaitingFirstRelocalisation
            awaitingFirstRelocalisation = false
            recognitionExtended = 0
            // Recognised: the room's coordinates moved to the saved map's. This session's outlines
            // go along (see `realign`), once ARKit has had a moment to move its own anchors.
            if wasFirstRelocalisation, let before = lastRecognisingCamera {
                let jump = camera.transform * simd_inverse(before)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.realign(by: jump) }
            }
            lastRecognisingCamera = nil
            // Back after being lost (not the first start): every object is checked again. Also
            // when the cues were shown again before ARKit had recognised the room.
            if trackingLost, !tracks.isEmpty { trackingRecovered = true }
            trackingLost = false
            trackingNormal = true
            // Locks made while the saved room was being recognised were held back until now.
            if wasFirstRelocalisation { DispatchQueue.main.async { [weak self] in self?.reconfigureImages() } }
        case .limited(.relocalizing):
            // Wait a while for ARKit to recognise the room; in another room it never will.
            let since = relocalisingSince ?? Date()
            relocalisingSince = since
            trackingNormal = false
            trackingLost = true
            let firstTry = awaitingFirstRelocalisation
            // Once per spell of recognising (ARKit may switch between limited states meanwhile).
            if checkScheduledFor != since {
                checkScheduledFor = since
                scheduleRecognitionCheck(since: since, firstTry: firstTry, after: firstTry ? recognitionWait : Self.relocaliseWait)
            }
            if firstTry {
                // Recognising a saved room at start: tracking runs, in the session's own
                // coordinates for now. This session's cues are drawn (remembered places wait until
                // the room is recognised, see renderNow).
                trackingNormal = true
                overlay.isHidden = false
                return
            }
        case .limited(.initializing):
            trackingNormal = false
            trackingLost = true
        case .limited, .notAvailable:
            // Fast motion or few features: keep drawing; the outlines may lag briefly.
            trackingNormal = true
        }
        overlay.isHidden = !trackingNormal
    }

    static let relocaliseWait: TimeInterval = 10
    /// At start with a saved room: ARKit often recognises it within a few seconds, sometimes only
    /// after the user looked around. Questions are answered meanwhile (the cues of this session are
    /// drawn and go along when the room is recognised, see `realign`); on 1 Nov the room of 17
    /// minutes before, in the same light, was given up after 6.7 s because the user spoke.
    static let firstRelocaliseWait: TimeInterval = 25
    /// For the next saved room, when the first was not it.
    static let nextRelocaliseWait: TimeInterval = 15
    /// Giving up wipes this session's outlines (a fresh start): while some are on screen it waits,
    /// up to this much longer in all.
    static let maxRecognitionExtension: TimeInterval = 60
    private var recognitionExtended: TimeInterval = 0
    /// The camera while ARKit was still recognising the room: its pose just before and just after
    /// recognition shows how far the room's coordinates moved.
    private var lastRecognisingCamera: simd_float4x4?
    private var checkScheduledFor: Date?
    private var recognitionWait = ARController.firstRelocaliseWait

    /// When the wait for a saved room is over: try another (or start fresh), unless this session's
    /// cues are on screen; then a while longer, since a fresh start would wipe them.
    private func scheduleRecognitionCheck(since: Date, firstTry: Bool, after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.relocalisingSince == since else { return }
            if firstTry, self.awaitingFirstRelocalisation {
                if self.hasPointedMarks, self.recognitionExtended < Self.maxRecognitionExtension {
                    self.recognitionExtended += 15
                    self.onLockLog?("map: still recognising the room; cues are on screen, so a while longer")
                    self.scheduleRecognitionCheck(since: since, firstTry: true, after: 15)
                    return
                }
                // The saved room is not this one: another saved room, or start fresh.
                self.onRelocaliseGaveUp?()
                return
            }
            self.trackingNormal = true
            self.overlay.isHidden = false
        }
    }
    private var relocalisingSince: Date?
    private(set) var awaitingFirstRelocalisation = false
    /// ARKit lost the room since tracking was last normal (`trackingNormal` may already be true
    /// again, when Pip gave up waiting and shows the cues anyway).
    private var trackingLost = false
    /// The saved room was not recognised at start.
    var onRelocaliseGaveUp: (() -> Void)?


    private func renderNow() {
        let now = CACurrentMediaTime()
        // The camera frame on screen: the outline must match it, not the world at this instant
        // (ARKit's frame is some 40-60 ms old when it is drawn).
        let shownFrame = arView.session.currentFrame?.timestamp ?? now
        let dt = lastRender > 0 ? min(0.1, now - lastRender) : 1.0 / 60
        lastRender = now
        // Steered outlines take up their latest mask (see `steerShape`); a face ARKit's image
        // tracking holds is drawn from the lock instead.
        let lockHeld = Set(imageLocks.values.filter { $0.seen && $0.tracked }.map(\.markID))
        for (id, shape) in steerShape where steered.contains(id) && !lockHeld.contains(id) && shape.shown != shape.target {
            guard let current = marks[id] else { continue }
            let moving = steerMotion[id].map { simd_length($0.velocity) > 0 } ?? false
            let k = Float(1 - exp(-dt / (moving ? Self.followMoving : Self.followStill)))
            var shown = shape.shown
            var settled = true
            for i in shown.indices {
                shown[i] += (shape.target[i] - shown[i]) * k
                if simd_distance(shown[i], shape.target[i]) > 0.0002 { settled = false }
            }
            if settled { shown = shape.target }
            steerShape[id] = (shown, shape.target)
            var m = AnchoredMark(id: id, world: [shown])
            m.lead = current.lead
            marks[id] = m
        }
        // Corrections and re-measurements ease in over about a fifth of a second.
        for (id, var m) in marks {
            var changed = false
            if let target = targetCorrections[id] {
                m.correction = Self.ease(m.correction, towards: target, by: 0.25)
                changed = true
            }
            if simd_length(m.glide) > 0.0005 {
                m.glide *= 0.8
                changed = true
            } else if m.glide != .zero {
                m.glide = .zero
                changed = true
            }
            // A moving object steered by EdgeTAM: drawn where it has got to since its mask.
            if let motion = steerMotion[id] {
                // Ahead by the mask's age at the shown frame, and by the time the drawn outline
                // takes to follow it.
                var lead = motion.velocity * Float(min(max(0, shownFrame - motion.time) + Self.followMoving, Self.maxLead))
                if simd_length(lead) > 0.05 { lead = simd_normalize(lead) * 0.05 }
                // Better, for a moving object: where the fast tracker saw it go since the mask's
                // frame, from the mask's own place (the drawn shape's easing made up for).
                if let live = edgeSpike.liveShift(id: id, since: motion.time, shown: shownFrame), let shape = steerShape[id] {
                    let s = min(1, max(0, (live.speed - 0.03) / 0.05))
                    let w = s * s * (3 - 2 * s)
                    var tracked = live.shift + Contour.centroid(shape.target) - Contour.centroid(shape.shown)
                    if simd_length(tracked) > 0.25 { tracked = simd_normalize(tracked) * 0.25 }
                    lead = tracked * w + lead * (1 - w)
                }
                if lead != m.lead { m.lead = lead; changed = true }
            }
            if changed { marks[id] = m }
        }
        for id in steered {
            guard let m = marks[id], !steerHidden.contains(id) else { continue }
            var h = drawnHistory[id] ?? []
            if h.last?.t != shownFrame { h.append((shownFrame, m.centroid)) }
            if h.count > 90 { h.removeFirst(h.count - 90) }
            drawnHistory[id] = h
        }
        trackVisibility(now: now)
        board.tick(now)
        // A locked object ARKit has lost sight of may have moved: its outline waits, hidden, until
        // ARKit finds the object again, rather than staying where the object was.
        var adjust = follower.adjust
        for lock in imageLocks.values where lock.seen && !lock.tracked && !(steered.contains(lock.markID) && !steerHidden.contains(lock.markID)) {
            adjust[lock.markID] = ImageFollower.Adjust(from: .zero, to: .zero, scale: 1, hidden: true)
        }
        for id in steerHidden where !imageLocks.values.contains(where: { $0.markID == id && $0.tracked }) {
            adjust[id] = ImageFollower.Adjust(from: .zero, to: .zero, scale: 1, hidden: true)
        }
        // While the saved room is being recognised, its remembered places are in its coordinates,
        // not yet in this session's: they wait.
        if awaitingFirstRelocalisation {
            for id in marks.keys where id >= Self.placeMarkBase { adjust[id] = ImageFollower.Adjust(from: .zero, to: .zero, scale: 1, hidden: true) }
        }
        overlay.adjust = adjust
        // Points behind the camera are never drawn (a projection would mirror them onto the
        // view); the edge arrow points the way instead, from the camera's own frame.
        let view = arView.session.currentFrame?.camera.viewMatrix(for: .portrait)
        func inCamera(_ p: simd_float3) -> simd_float4? { view.map { $0 * simd_float4(p, 1) } }
        overlay.render(board.annotations, now: now, marks: marks, project: { [arView] p in
            if let c = inCamera(p), c.z > -0.05 { return nil }
            return arView.project(p)
        }, direction: { p in
            // x right and y up in the portrait camera frame; straight behind: turn right.
            guard let c = inCamera(p) else { return nil }
            return abs(c.x) + abs(c.y) < 1e-4 ? CGVector(dx: 1, dy: 0) : CGVector(dx: CGFloat(c.x), dy: CGFloat(-c.y))
        })
        shots.frame(now: now, cuesDrawn: board.annotations.contains { $0.cue.isDrawn && !$0.cue.marks.isEmpty }, arView: arView, overlay: overlay)
    }

    /// Pointed-at objects with a cue on screen, followed in the image (see ImageFollower).
    private func followObjects(_ frame: ARFrame) {
        let locked = Set(imageLocks.values.filter(\.seen).map(\.markID)).union(steered)
        let shownIDs = Set(board.annotations.flatMap { $0.cue.marks }).filter { $0 < Self.placeMarkBase && tracks[$0] != nil && !locked.contains($0) }
        guard !shownIDs.isEmpty else { return }
        var shown: [(id: Int, box: CGRect)] = []
        for id in shownIDs.sorted() {
            guard let m = marks[id] else { continue }
            let pts = m.polygons.flatMap { $0 }.compactMap { arView.project($0 - m.glide) }
            guard pts.count >= 3 else { continue }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            guard box.intersects(arView.bounds) else { continue }
            shown.append((id, box))
        }
        follower.update(frame: frame, shown: shown, viewSize: arView.bounds.size)
    }

    /// A box in screen points as pixels of `snapshot` (taken from the current frame).
    func snapshotBox(screen r: CGRect, snapshot: FrameSnapshot) -> CGRect? {
        guard let frame = arView.session.currentFrame, arView.bounds.width > 0 else { return nil }
        let size = arView.bounds.size
        let toImage = frame.displayTransform(for: .portrait, viewportSize: size).inverted()
        let n = CGRect(x: r.minX / size.width, y: r.minY / size.height, width: r.width / size.width, height: r.height / size.height)
        let img = n.applying(toImage).standardized
        // Sensor (landscape) normalised → upright pixels: upright x = (1 − y) · width, upright y = x · height.
        let w = CGFloat(snapshot.image.width), h = CGFloat(snapshot.image.height)
        return CGRect(x: (1 - img.maxY) * w, y: img.minX * h, width: img.height * w, height: img.width * h)
    }

    /// Notes when each object leaves and re-enters the view, so it is checked when it comes back.
    private func trackVisibility(now: TimeInterval) {
        guard !tracks.isEmpty else { return }
        let bounds = arView.bounds
        for (id, var track) in tracks {
            guard let m = marks[id] else { continue }
            let inView = arView.project(m.centroid).map { bounds.contains($0) } ?? false
            if track.noteVisible(inView, now: now) { tracks[id] = track }
        }
    }

    /// A rigid transform part of the way towards another: position eased linearly, rotation along the arc.
    static func ease(_ a: simd_float4x4, towards b: simd_float4x4, by t: Float) -> simd_float4x4 {
        let qa = simd_quatf(a), qb = simd_quatf(b)
        var m = simd_float4x4(simd_slerp(qa, qb, t))
        m.columns.3 = simd_mix(a.columns.3, b.columns.3, simd_float4(repeating: t))
        m.columns.3.w = 1
        return m
    }

    // MARK: Remembered places

    /// Turns a pointed-at object into a remembered place with its own ARKit anchor.
    func rememberPlace(name: String, mark: Int) -> SpaceMemory.Place? {
        guard let m = marks[mark] else { return nil }
        // Naming a place again moves it.
        for (id, old) in places where old.name.lowercased() == name.lowercased() {
            removeMarks { $0 == id }
            places[id] = nil
            restoredPlaces.removeAll { $0.id == old.id }
        }
        let world = m.polygons
        var t = matrix_identity_float4x4
        t.columns.3 = simd_float4(m.centroid, 1)
        let anchor = ARAnchor(name: "pip-place", transform: t)
        arView.session.add(anchor: anchor)
        let inverse = simd_inverse(t)
        let local = world.map { ring in ring.map { p -> SIMD3<Float> in let q = inverse * simd_float4(p, 1); return SIMD3(q.x, q.y, q.z) } }
        let spec = tracks[mark]?.spec
        let place = SpaceMemory.Place(id: UUID(), name: name, anchorID: anchor.identifier, outline: local, created: Date(), pose: Self.values(t),
                                      phrase: spec?.phrase, text: spec?.text)
        install(place, anchor: anchor, measured: true)
        return place
    }

    /// A place from a map piece that was just linked: `transform` takes its piece's frame into
    /// this session's. It gets a new anchor here, so the next saved map holds it too.
    func installLinked(_ place: SpaceMemory.Place, transform: simd_float4x4) -> SpaceMemory.Place? {
        guard let values = place.pose, values.count == 16, !places.values.contains(where: { $0.id == place.id }) else { return nil }
        let pose = transform * Self.matrix(values)
        let anchor = ARAnchor(name: "pip-place", transform: pose)
        arView.session.add(anchor: anchor)
        var moved = place
        moved.anchorID = anchor.identifier
        moved.pose = Self.values(pose)
        install(moved, anchor: anchor)
        return moved
    }

    static func values(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    static func matrix(_ v: [Float]) -> simd_float4x4 {
        simd_float4x4(columns: (simd_float4(v[0], v[1], v[2], v[3]), simd_float4(v[4], v[5], v[6], v[7]),
                                simd_float4(v[8], v[9], v[10], v[11]), simd_float4(v[12], v[13], v[14], v[15])))
    }

    /// Places from memory: they appear once ARKit has restored their anchors from the room map.
    func restore(_ saved: [SpaceMemory.Place]) {
        for p in saved { pendingPlaces[p.anchorID] = p }
        for anchor in arView.session.currentFrame?.anchors ?? [] { restorePlace(anchor) }
    }

    private func restorePlace(_ anchor: ARAnchor) {
        guard var place = pendingPlaces.removeValue(forKey: anchor.identifier) else { return }
        // ARKit knows where the anchor is in this map: keep that, so the place can also be
        // brought back by linking pieces later.
        place.pose = Self.values(anchor.transform)
        install(place, anchor: anchor)
        restoredPlaces.append(place)
    }

    /// Places ARKit restored from the saved map, with their pose now known (to store once).
    var restoredPlaces: [SpaceMemory.Place] = []

    /// `measured`: just pointed at in this session. Otherwise (from storage or a linked piece)
    /// Pip finds it again the first time it points at it, and corrects its position.
    private func install(_ place: SpaceMemory.Place, anchor: ARAnchor, measured: Bool = false) {
        let id = nextPlaceMark
        nextPlaceMark += 1
        let t = anchor.transform
        let world = place.outline.map { ring in ring.map { p -> simd_float3 in let q = t * simd_float4(p, 1); return simd_float3(q.x, q.y, q.z) } }
        marks[id] = AnchoredMark(id: id, world: world)
        anchors[id] = (anchor, t)
        places[id] = place
        if !measured, let phrase = place.phrase {
            tracks[id] = ObjectTrack(place: TargetSpec(x: 500, y: 500, phrase: phrase, text: place.text ?? []), now: CACurrentMediaTime())
        }
    }

    /// The session drifted against the map piece these places came from: move them along.
    func applyDrift(_ delta: simd_float4x4, toPlaces ids: Set<UUID>) {
        for (id, stored) in places where ids.contains(stored.id) {
            guard let m = marks[id] else { continue }
            let before = m.centroid
            let world = m.polygons.map { ring in ring.map { (delta * simd_float4($0 - m.glide, 1)).xyz } }
            place(AnchoredMark(id: id, world: world), glideFrom: before)
        }
    }

    /// A remembered place was measured again: its new pose and outline, to store.
    var onPlaceMoved: ((SpaceMemory.Place) -> Void)?

    func forgetPlace(_ placeID: UUID) {
        pendingPlaces = pendingPlaces.filter { $0.value.id != placeID }
        // Or the next save would write it back.
        restoredPlaces.removeAll { $0.id == placeID }
        guard let (id, _) = places.first(where: { $0.value.id == placeID }) else { return }
        removeMarks { $0 == id }
        places[id] = nil
    }

    /// Every place, also the ones only known this session.
    func forgetAllPlaces() {
        pendingPlaces = [:]
        restoredPlaces = []
        removeMarks { $0 >= Self.placeMarkBase }
        places = [:]
    }

    /// Remembered places as marks the model may point at.
    var placeMarks: [Int: MarkInfo] {
        Dictionary(uniqueKeysWithValues: places.keys.filter { marks[$0] != nil }.map { ($0, MarkInfo(id: $0, confidence: 0.95)) })
    }

    /// Where each remembered place is from the user right now, in words the model can pass on.
    func placeDescriptions() -> [String] {
        places.sorted { $0.key < $1.key }.compactMap { id, place in
            describe(mark: id, dutch: false).map { "\(id): \(place.name) — \($0)" }
        }
    }

    /// Where a mark is from the user now: distance, side, height, and whether it is in view.
    func describe(mark id: Int, dutch: Bool) -> String? {
        guard let frame = arView.session.currentFrame, let m = marks[id] else { return nil }
        let cam = frame.camera.transform
        let pos = simd_float3(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let v = m.centroid - pos
        // Left and right from where the camera looks and gravity: however the phone is held.
        let angle = Wayfinding.bearing(to: m.centroid, camera: cam)
        let side: String
        switch abs(angle) {
        case ..<25: side = dutch ? "voor je" : "ahead"
        case ..<70: side = angle > 0 ? (dutch ? "schuin rechts voor je" : "ahead to the right") : (dutch ? "schuin links voor je" : "ahead to the left")
        case ..<125: side = angle > 0 ? (dutch ? "rechts van je" : "to the right") : (dutch ? "links van je" : "to the left")
        default: side = angle > 0 ? (dutch ? "achter je, rechts" : "behind you, to the right") : (dutch ? "achter je, links" : "behind you, to the left")
        }
        let height = v.y > 0.5 ? (dutch ? ", hoger" : ", higher up") : (v.y < -0.6 ? (dutch ? ", lager" : ", lower down") : "")
        let p = arView.project(m.centroid)
        let inView = (p.map { arView.bounds.contains($0) } ?? false) && abs(angle) < 60
        let distance = String(format: dutch ? "%.1f meter" : "%.1f m", simd_length(v)).replacingOccurrences(of: dutch ? "." : "#", with: dutch ? "," : "#")
        return "\(distance), \(side)\(height); " + (inView ? (dutch ? "in beeld" : "in view") : (dutch ? "niet in beeld" : "not in view"))
    }

    /// A found object from the visual memory, outlined in the room (not remembered across
    /// sessions). The previous found object gives way.
    func addFound(world polygons: [[simd_float3]], id: Int) {
        removeMarks { $0 >= Self.foundMarkBase && $0 < Self.placeMarkBase }
        let m = AnchoredMark(id: id, world: polygons)
        place(m)
    }

    /// Saves the room map with the places' anchors only (outline anchors are for this session).
    /// ARKit needs to have mapped enough of the room first: Pip waits and tries again. `store`
    /// gets nil when Pip gives up.
    /// `store` gets the map, or nil with the reason it was not good enough.
    func saveMap(attempt: Int = 0, _ store: @escaping (ARWorldMap?, String) -> Void) {
        // While ARKit is still recognising the saved room, this session's map is in a frame of
        // its own: saving it would spoil the room's map.
        guard !awaitingFirstRelocalisation else { store(nil, "the saved room is not recognised yet"); return }
        let status = arView.session.currentFrame?.worldMappingStatus
        // Only a map ARKit itself calls good (as MultiSet keeps its maps clean), and only after a
        // while of steady tracking in enough light: in the dark or after a loss ARKit's map drifts
        // (31 Oct: saved at 74 × 118 m after the camera had been dark, and never recognised).
        let steady = CACurrentMediaTime() - lastTrackingTrouble >= Self.steadyBeforeSave
        guard steady, status == .mapped || status == .extending else {
            if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.saveMap(attempt: attempt + 1, store) }
            } else {
                store(nil, steady ? "the map is not good enough yet" : "tracking was not steady")
            }
            return
        }
        arView.session.getCurrentWorldMap { [weak self] map, _ in
            DispatchQueue.main.async {
                guard let map else {
                    if attempt < 5, let self { self.saveMap(attempt: attempt + 1, store) } else { store(nil, "ARKit gave no map") }
                    return
                }
                // A home is not that large: such a map has drifted.
                let size = Self.robustExtent(map.rawFeaturePoints.points)
                guard max(size.x, size.y) <= Self.maxMapExtent else {
                    store(nil, String(format: "it has drifted (%.0f × %.0f m)", size.x, size.y))
                    return
                }
                // A map of a metre or so is recognised from that one view only (31 Oct: saved 10 s
                // after start at 1.2 × 1.3 m, then tried first at the next start): it waits until
                // it covers more of the room.
                guard max(size.x, size.y) >= Self.minMapExtent, map.rawFeaturePoints.points.count >= Self.minMapPoints else {
                    store(nil, String(format: "it covers too little yet (%.1f × %.1f m, %d points)", size.x, size.y, map.rawFeaturePoints.points.count))
                    return
                }
                map.anchors = map.anchors.filter { $0.name == "pip-place" }
                store(map, String(format: "%.1f × %.1f m", size.x, size.y))
            }
        }
    }

    /// Steady tracking this long before a map is saved.
    static let steadyBeforeSave: TimeInterval = 5
    /// No home map is wider than this (2nd to 98th percentile of its feature points, across the floor).
    static let maxMapExtent: Float = 25
    /// A map is worth keeping from this size on.
    static let minMapExtent: Float = 1.5
    static let minMapPoints = 2000
    /// When tracking was last limited, lost or in the dark.
    private var lastTrackingTrouble: CFTimeInterval = 0

    /// The span of the points across the floor (x and z), ignoring the 2 % furthest on each side.
    static func robustExtent(_ points: [simd_float3]) -> SIMD2<Float> {
        guard points.count >= 10 else { return .zero }
        let xs = points.map(\.x).sorted(), zs = points.map(\.z).sorted()
        let lo = points.count / 50, hi = points.count - 1 - points.count / 50
        return SIMD2(xs[hi] - xs[lo], zs[hi] - zs[lo])
    }
}
