import ARKit
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
        let config = ARWorldTrackingConfiguration()
        // A saved room map: ARKit recognises the room again and restores the remembered places.
        config.initialWorldMap = initialMap
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        // Depth averaged over recent frames: less noise, so outlines sit more exactly.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        arView.renderOptions.insert(.disableMotionBlur)
        arView.session.delegate = self
        arView.session.run(config)
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

    /// Lifts one grounded instance into 3D. Returns how it was anchored, for the trace.
    @discardableResult
    func addMark(_ inst: SegmentInstance, snapshot: FrameSnapshot) -> String {
        // Clean, regular shapes: a raw mask outline looks hand-drawn once stroked on screen.
        guard let m = AnchoredMark(inst.regularized(), snapshot: snapshot) else { return "no outline" }
        place(m)
        return m.method
    }

    /// Replaces a mark with a fresh measurement of the same object (it moved, or the user came back).
    @discardableResult
    func updateMark(_ inst: SegmentInstance, snapshot: FrameSnapshot) -> Bool {
        guard marks[inst.id] != nil, let m = AnchoredMark(inst.regularized(), snapshot: snapshot) else { return false }
        place(m)
        return true
    }

    private func place(_ m: AnchoredMark) {
        if let old = anchors[m.id] { arView.session.remove(anchor: old.anchor) }
        var t = matrix_identity_float4x4
        t.columns.3 = simd_float4(m.placement, 1)
        let anchor = ARAnchor(name: "pip-mark", transform: t)
        arView.session.add(anchor: anchor)
        anchors[m.id] = (anchor, t)
        marks[m.id] = m
    }

    private func removeMarks(where shouldRemove: (Int) -> Bool) {
        for id in marks.keys where shouldRemove(id) {
            if let a = anchors[id] { arView.session.remove(anchor: a.anchor) }
            anchors[id] = nil
            marks[id] = nil
        }
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
        // ARKit moves anchors when it corrects its map (loop closure, relocalisation).
        if !anchors.isEmpty {
            let current = Dictionary(frame.anchors.map { ($0.identifier, $0.transform) }, uniquingKeysWith: { a, _ in a })
            for (id, entry) in anchors {
                guard let now = current[entry.anchor.identifier] else { continue }
                marks[id]?.correction = now * simd_inverse(entry.origin)
            }
        }
        renderNow()
    }

    func session(_ session: ARSession, didAdd added: [ARAnchor]) {
        for anchor in added { restorePlace(anchor) }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            relocalisingSince = nil
            trackingNormal = true
        case .limited(.relocalizing):
            // Wait a while for ARKit to recognise the room; in another room it never will.
            let since = relocalisingSince ?? Date()
            relocalisingSince = since
            trackingNormal = false
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.relocaliseWait) { [weak self] in
                guard let self, self.relocalisingSince == since else { return }
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
    private var relocalisingSince: Date?


    private func renderNow() {
        let now = CACurrentMediaTime()
        board.tick(now)
        overlay.render(board.annotations, now: now, marks: marks) { [arView] p in arView.project(p) }
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
        let place = SpaceMemory.Place(id: UUID(), name: name, anchorID: anchor.identifier, outline: local, created: Date())
        install(place, anchor: anchor)
        return place
    }

    /// Places from memory: they appear once ARKit has restored their anchors from the room map.
    func restore(_ saved: [SpaceMemory.Place]) {
        for p in saved { pendingPlaces[p.anchorID] = p }
        for anchor in arView.session.currentFrame?.anchors ?? [] { restorePlace(anchor) }
    }

    private func restorePlace(_ anchor: ARAnchor) {
        guard let place = pendingPlaces.removeValue(forKey: anchor.identifier) else { return }
        install(place, anchor: anchor)
    }

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
