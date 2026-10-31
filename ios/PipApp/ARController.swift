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
        // The room's surfaces as a mesh: Pip's 3D map of the home is built from it.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        return config
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

    /// The room's surfaces ARKit has meshed so far, as points 4 cm apart (world space).
    func meshPoints() -> [simd_float3] {
        let meshes = (arView.session.currentFrame?.anchors ?? []).compactMap { $0 as? ARMeshAnchor }
        var points: [simd_float3] = []
        for mesh in meshes {
            let vertices = mesh.geometry.vertices
            let base = vertices.buffer.contents().advanced(by: vertices.offset)
            let t = mesh.transform
            for i in 0..<vertices.count {
                let v = base.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
                let p = t * simd_float4(v[0], v[1], v[2], 1)
                points.append(simd_float3(p.x, p.y, p.z))
            }
        }
        return VoxelIndex.downsample(points, size: 0.04)
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
            tracks[m.id] = ObjectTrack(observation: obs, spec: spec, box: inst.boxRect, imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height))
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
        var track = tracks[inst.id] ?? ObjectTrack(observation: obs, spec: nil, box: inst.boxRect, imageSize: .zero)
        // Earlier views were taken before ARKit's latest correction of this anchor: bring them along.
        let correction = targetCorrections[inst.id] ?? matrix_identity_float4x4
        let predicted = old.centroid
        let pixelError = snapshot.project(predicted).map { hypot($0.x - inst.centre.x, $0.y - inst.centre.y) }
        let update = track.add(obs, correction: correction, reason: reason, predicted: predicted)
        track.box = inst.boxRect
        tracks[inst.id] = track
        let placed = update.position.map { fresh.relocated(to: $0) } ?? fresh
        place(placed, glideFrom: predicted)
        var result = update
        result.pixelError = pixelError.map(Double.init)
        result.method = placed.method
        return result
    }

    private func place(_ m: AnchoredMark, glideFrom previous: simd_float3? = nil) {
        if let old = anchors[m.id] { arView.session.remove(anchor: old.anchor) }
        var t = matrix_identity_float4x4
        t.columns.3 = simd_float4(m.placement, 1)
        let anchor = ARAnchor(name: "pip-mark", transform: t)
        arView.session.add(anchor: anchor)
        anchors[m.id] = (anchor, t)
        targetCorrections[m.id] = nil
        var m = m
        if let previous { m.glide = previous - m.centroid }
        marks[m.id] = m
    }

    private func removeMarks(where shouldRemove: (Int) -> Bool) {
        for id in marks.keys where shouldRemove(id) {
            if let a = anchors[id] { arView.session.remove(anchor: a.anchor) }
            anchors[id] = nil
            marks[id] = nil
            tracks[id] = nil
            targetCorrections[id] = nil
        }
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
        for (id, box) in visibleMarkBoxes(in: snapshot) where id < Self.placeMarkBase {
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

    /// Whether any look's or found object's mark has a cue on screen (re-measuring has work to do).
    var hasPointedMarks: Bool {
        board.annotations.contains { $0.cue.marks.contains { $0 < Self.placeMarkBase && marks[$0] != nil } }
    }


    // MARK: ARSessionDelegate

    /// Called for every camera frame (reading mode uses it to take pages).
    var onFrame: ((ARFrame) -> Void)?

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        onFrame?(frame)
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
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            relocalisingSince = nil
            awaitingFirstRelocalisation = false
            // Back after being lost (not the first start): every object is checked again.
            if !trackingNormal, !tracks.isEmpty { trackingRecovered = true }
            trackingNormal = true
        case .limited(.relocalizing):
            // Wait a while for ARKit to recognise the room; in another room it never will.
            let since = relocalisingSince ?? Date()
            relocalisingSince = since
            trackingNormal = false
            let firstTry = awaitingFirstRelocalisation
            DispatchQueue.main.asyncAfter(deadline: .now() + (firstTry ? Self.firstRelocaliseWait : Self.relocaliseWait)) { [weak self] in
                guard let self, self.relocalisingSince == since else { return }
                if firstTry, self.awaitingFirstRelocalisation {
                    // The saved room is not this one: start fresh; the map links it later.
                    self.onRelocaliseGaveUp?()
                    return
                }
                self.trackingNormal = true
                self.overlay.isHidden = false
            }
        case .limited(.initializing):
            trackingNormal = false
        case .limited, .notAvailable:
            // Fast motion or few features: keep drawing; the outlines may lag briefly.
            trackingNormal = true
        }
        overlay.isHidden = !trackingNormal
    }

    static let relocaliseWait: TimeInterval = 10
    /// At start with a saved room: ARKit recognises it within a few seconds when Pip is in it.
    static let firstRelocaliseWait: TimeInterval = 8
    private var relocalisingSince: Date?
    private var awaitingFirstRelocalisation = false
    /// The saved room was not recognised at start.
    var onRelocaliseGaveUp: (() -> Void)?


    private func renderNow() {
        let now = CACurrentMediaTime()
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
            if changed { marks[id] = m }
        }
        trackVisibility(now: now)
        board.tick(now)
        overlay.render(board.annotations, now: now, marks: marks) { [arView] p in arView.project(p) }
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
        }
        let world = m.polygons
        var t = matrix_identity_float4x4
        t.columns.3 = simd_float4(m.centroid, 1)
        let anchor = ARAnchor(name: "pip-place", transform: t)
        arView.session.add(anchor: anchor)
        let inverse = simd_inverse(t)
        let local = world.map { ring in ring.map { p -> SIMD3<Float> in let q = inverse * simd_float4(p, 1); return SIMD3(q.x, q.y, q.z) } }
        let place = SpaceMemory.Place(id: UUID(), name: name, anchorID: anchor.identifier, outline: local, created: Date(), pose: Self.values(t))
        install(place, anchor: anchor)
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

    private func install(_ place: SpaceMemory.Place, anchor: ARAnchor) {
        let id = nextPlaceMark
        nextPlaceMark += 1
        let t = anchor.transform
        let world = place.outline.map { ring in ring.map { p -> simd_float3 in let q = t * simd_float4(p, 1); return simd_float3(q.x, q.y, q.z) } }
        marks[id] = AnchoredMark(id: id, world: world)
        anchors[id] = (anchor, t)
        places[id] = place
    }

    func forgetPlace(_ placeID: UUID) {
        pendingPlaces = pendingPlaces.filter { $0.value.id != placeID }
        guard let (id, _) = places.first(where: { $0.value.id == placeID }) else { return }
        removeMarks { $0 == id }
        places[id] = nil
    }

    /// Every place, also the ones only known this session.
    func forgetAllPlaces() {
        pendingPlaces = [:]
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
        let forward = -simd_float3(cam.columns.2.x, 0, cam.columns.2.z)
        let right = simd_float3(cam.columns.0.x, 0, cam.columns.0.z)
        let v = m.centroid - pos
        let flat = simd_float3(v.x, 0, v.z)
        let angle = atan2(simd_dot(flat, simd_normalize(right)), simd_dot(flat, simd_normalize(forward))) * 180 / .pi
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
    /// ARKit needs to have mapped enough of the room first: Pip waits and tries again.
    func saveMap(attempt: Int = 0, _ store: @escaping (ARWorldMap) -> Void) {
        let status = arView.session.currentFrame?.worldMappingStatus
        guard status == .mapped || status == .extending || attempt >= 5 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.saveMap(attempt: attempt + 1, store) }
            return
        }
        arView.session.getCurrentWorldMap { [weak self] map, _ in
            DispatchQueue.main.async {
                guard let map else {
                    if attempt < 5 { self?.saveMap(attempt: attempt + 1, store) }
                    return
                }
                map.anchors = map.anchors.filter { $0.name == "pip-place" }
                store(map)
            }
        }
    }
}
