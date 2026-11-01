import ARKit
import PipCore
import QuartzCore
import RealityKit
import simd

/// Remembered places: their anchors in the room map, found objects, and saving the map.
extension ARController {
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
        let spec = tracks[mark]?.spec
        let place = SpaceMemory.Place(id: UUID(), name: name, anchorID: anchor.identifier, outline: local, created: Date(), pose: Self.values(t),
                                      phrase: spec?.phrase, text: spec?.text)
        install(place, anchor: anchor, measured: true)
        return place
    }

    static func values(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    static func matrix(_ v: [Float]) -> simd_float4x4 {
        simd_float4x4(columns: (simd_float4(v[0], v[1], v[2], v[3]), simd_float4(v[4], v[5], v[6], v[7]),
                                simd_float4(v[8], v[9], v[10], v[11]), simd_float4(v[12], v[13], v[14], v[15])))
    }

    /// A remembered place of an earlier session linked to this one (SpaceLinker): on an anchor of its
    /// own where the link carries it. Not stored until found again on sight (its position here is
    /// only as good as the link until then).
    func restoreLinked(_ place: SpaceMemory.Place, at transform: simd_float4x4) {
        let anchor = ARAnchor(name: "pip-place", transform: transform)
        arView.session.add(anchor: anchor)
        install(place, anchor: anchor)
    }

    /// `measured`: just pointed at in this session. Otherwise (from storage) Pip finds it again
    /// the first time it points at it, and corrects its position.
    func install(_ place: SpaceMemory.Place, anchor: ARAnchor, measured: Bool = false) {
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

    func forgetPlace(_ placeID: UUID) {
        guard let (id, _) = places.first(where: { $0.value.id == placeID }) else { return }
        removeMarks { $0 == id }
        places[id] = nil
    }

    /// Every place, also the ones only known this session.
    func forgetAllPlaces() {
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
    func addFound(world polygons: [[simd_float3]], id: Int, spec: TargetSpec? = nil) {
        removeMarks { $0 >= Self.foundMarkBase && $0 < Self.placeMarkBase }
        let m = AnchoredMark(id: id, world: polygons)
        place(m)
        // Found in a snapshot (possibly of an earlier session): found again on sight and corrected,
        // like a remembered place.
        if let spec { tracks[id] = ObjectTrack(place: spec, now: CACurrentMediaTime()) }
    }

    /// Saves the room map with the places' anchors only (outline anchors are for this session).
    /// ARKit needs to have mapped enough of the room first: Pip waits and tries again. `store`
    /// gets nil when Pip gives up.
    /// `store` gets the map, or nil with the reason it was not good enough.
    func saveMap(attempt: Int = 0, _ store: @escaping (ARWorldMap?, String) -> Void) {
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

    /// The span of the points across the floor (x and z), ignoring the 2 % furthest on each side.
    static func robustExtent(_ points: [simd_float3]) -> SIMD2<Float> {
        guard points.count >= 10 else { return .zero }
        let xs = points.map(\.x).sorted(), zs = points.map(\.z).sorted()
        let lo = points.count / 50, hi = points.count - 1 - points.count / 50
        return SIMD2(xs[hi] - xs[lo], zs[hi] - zs[lo])
    }
}
