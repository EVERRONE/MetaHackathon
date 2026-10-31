import ARKit
import Foundation
import UIKit
import PipCore
import simd

/// Long-term memory: places in the room and facts about the user's devices, kept across sessions
/// only after the user said yes, and only on this iPhone.
extension GuideModel {
    // MARK: The map of the home

    /// At launch, without the user doing anything: ARKit is handed the map of the room used last,
    /// and recognises it within seconds if Pip is in it (its places come back on their anchors).
    /// If not, the saved room that holds the most of the home is tried; if that is not it either,
    /// Pip maps this room as a new piece. Each session extends the map of the room it recognised
    /// as the user walks, also into rooms not mapped yet, and the map is saved whenever ARKit
    /// calls it good: rooms join up by being walked through, and the user never maps on purpose.
    func startMap() {
        memory.migrateLegacyMap()
        let pieces = memory.consent == true ? MapStore.loadAll() : []
        // Only rooms that can be here: a map made in another home or building is not tried (the
        // phone's rough location; pieces without one are kept).
        if memory.consent == true { homeLocation.start() }
        let here = homeLocation.point
        let nearby = pieces.filter { p in
            guard let here, let there = p.location else { return true }
            return here.couldBeSamePlace(as: there)
        }
        if let here, nearby.count < pieces.count {
            let far = pieces.compactMap { $0.location?.distance(to: here) }.min() ?? 0
            Relocalisation.log(String(format: "location: %d of %d saved pieces are elsewhere (the nearest %.1f km away), not tried", pieces.count - nearby.count, pieces.count, far / 1000))
        }
        // Most promising first: the room used last (of the ones mapped over a while), then the one
        // with the most places and views.
        let saved = nearby.filter { MapStore.hasWorldMap($0.id) }
        func worth(_ p: MapPiece) -> Int { memory.places.filter { $0.piece == p.id }.count * 20 + p.keyframes.count }
        var order: [MapPiece] = []
        let substantial = saved.filter { $0.keyframes.count >= 10 }
        if let recent = (substantial.isEmpty ? saved : substantial).max(by: { $0.updated < $1.updated }) { order.append(recent) }
        if let richest = saved.filter({ $0.id != order.first?.id }).max(by: { worth($0) < worth($1) }) { order.append(richest) }
        var worldMap: ARWorldMap?
        var continuing: MapPiece?
        while worldMap == nil, !order.isEmpty {
            let p = order.removeFirst()
            worldMap = usableMap(p)
            if worldMap != nil { continuing = p }
        }
        mapCandidates = order
        ar.relocalisation.onStatus = { [weak self] s in self?.ar.setSpikeStatus("map", s) }
        // The location can come in a second or two after start: a room from elsewhere is given up then.
        homeLocation.onUpdate = { [weak self] here in self?.locationArrived(here) }
        ar.relocalisation.onHint = { [weak self] hint in self?.mappingHint(hint) }
        ar.relocalisation.trying(continuing.map { String($0.id.uuidString.prefix(4)) }, detail: continuing.map(describe) ?? "\(pieces.count) pieces stored")
        mapKeeper.enabled = memory.consent == true
        mapKeeper.begin(continuing: continuing, others: pieces.filter { $0.id != continuing?.id })
        mapKeeper.onLog = { [weak self] line in self?.log(line) }
        mapKeeper.onLink = { [weak self] piece, refined, transform in self?.linked(piece, refined: refined, transform: transform) }
        ar.onRelocaliseGaveUp = { [weak self] in self?.relocalisationGaveUp() }
        ar.onMovedObjectSettled = { [weak self] id, box in
            Task { @MainActor in await self?.remeasureMoved(id, screenBox: box) }
        }
        ar.follower.onLog = { [weak self] line in self?.log(line) }
        ar.onLockLog = { [weak self] line in self?.log(line) }
        ar.onPlaceMoved = { [weak self] place in
            guard let self else { return }
            var p = place
            p.piece = self.mapKeeper.current.id
            self.memory.update([p])
            self.saveRoomSoon()
        }
        mapKeeper.meshNear = { [weak self] centre, radius in self?.ar.meshPoints(near: centre, radius: radius) ?? [] }
        mapKeeper.onDrift = { [weak self] piece, delta in
            guard let self else { return }
            self.ar.applyDrift(delta, toPlaces: self.linkedPlaces[piece] ?? [])
        }
        ar.start(initialMap: worldMap)
        // The week's snapshots: those of the room ARKit is recognising can be pointed at.
        keyframes.persist = memory.consent == true
        keyframes.currentPiece = mapKeeper.current.id
        keyframes.load(locatedPiece: continuing?.id)
        // Places of the piece ARKit is recognising come back on their own anchors.
        ar.restore(memory.places.filter { $0.piece == nil || $0.piece == continuing?.id })
        if continuing != nil { log("map: recognising the room of last time") }
        mapSaveTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.mapKeeper.dirty else { return }
                self.saveRoomNow()
            }
        }
    }

    /// The user asked something while ARKit still tries a saved room: no more tries this session.
    func giveUpRecognising(because reason: String = "the user asked something") {
        log("map: \(reason); no more waiting for a saved room")
        mapCandidates = []
        relocalisationGaveUp()
    }

    private func relocalisationGaveUp() {
        ar.relocalisation.gaveUp()
        // Another saved room first, if there is one.
        while let next = mapCandidates.first {
            mapCandidates.removeFirst()
            guard let map = usableMap(next) else { continue }
            log("map: not the room of last time; trying another saved room")
            ar.restart(initialMap: map)
            let others = mapKeeper.others.filter { $0.id != next.id } + (mapKeeper.current.keyframes.isEmpty ? [] : [mapKeeper.current])
            mapKeeper.begin(continuing: next, others: others)
            keyframes.locate(next.id)
            ar.restore(memory.places.filter { $0.piece == nil || $0.piece == next.id })
            ar.relocalisation.trying(String(next.id.uuidString.prefix(4)), detail: describe(next))
            return
        }
        log("map: not a saved room; mapping this one as a new piece")
        ar.restartFresh()
        mapKeeper.startNewPiece()
        keyframes.pieceChanged(to: mapKeeper.current.id)
        ar.relocalisation.trying(nil, detail: "after the saved rooms")
    }

    /// A saved room's map, unless it drifted when it was saved (older versions saved such maps).
    private func usableMap(_ p: MapPiece) -> ARWorldMap? {
        guard let map = MapStore.loadWorldMap(p.id) else { return nil }
        let size = ARController.robustExtent(map.rawFeaturePoints.points)
        guard max(size.x, size.y) <= ARController.maxMapExtent else {
            Relocalisation.log(String(format: "piece %@ skipped: its map has drifted (%.0f × %.0f m)", String(p.id.uuidString.prefix(4)), size.x, size.y))
            return nil
        }
        return map
    }

    /// A fix came in: kept with this piece, and if ARKit is still trying a room that was mapped
    /// elsewhere, it stops trying.
    private func locationArrived(_ here: GeoPoint) {
        mapCandidates.removeAll { p in p.location.map { !here.couldBeSamePlace(as: $0) } ?? false }
        if ar.awaitingFirstRelocalisation {
            // The piece being tried keeps its own location until ARKit recognises it.
            guard let there = mapKeeper.current.location, !here.couldBeSamePlace(as: there) else { return }
            Relocalisation.log(String(format: "location: the room being tried was mapped %.1f km from here; not waiting for it", here.distance(to: there) / 1000))
            giveUpRecognising(because: "it was mapped elsewhere")
        }
        mapKeeper.setLocation(here)
    }

    private func describe(_ p: MapPiece) -> String {
        let places = memory.places.filter { $0.piece == p.id }.count
        return String(format: "%d keyframes, %d places, %.1f h old", p.keyframes.count, places, Date().timeIntervalSince(p.updated) / 3600)
    }

    /// The mapping needs the user's help: said once in a while, only when Pip is free.
    func mappingHint(_ hint: Relocalisation.Hint) {
        let key = "\(hint)"
        // Looking around is asked once per start; the others at most every three minutes.
        let wait: TimeInterval = hint == .lookAround ? .infinity : 180
        if let last = hintSaid[key], wait == .infinity || Date().timeIntervalSince(last) < wait { return }
        guard !speaker.isSpeaking, !lookActive, phase == .listening else { return }
        hintSaid[key] = Date()
        log("map hint: \(key)")
        switch hint {
        case .moveSlower: say(phrases.moveSlower)
        case .lookAround: say(phrases.lookAround)
        case .moreFeatures: say(phrases.moreFeatures)
        }
    }

    /// A stored piece was recognised and linked: its places come into this session, and Pip says so.
    /// Each place lands within the link's uncertainty (logged); the first time Pip points at it, it
    /// is found again on sight and corrected to the centimetre.
    private func linked(_ piece: MapPiece, refined: MapLinker.Refined, transform: simd_float4x4) {
        let moved = memory.places.filter { $0.piece == piece.id }.compactMap { place -> SpaceMemory.Place? in
            if let pose = place.pose, pose.count == 16 {
                let at = ARController.matrix(pose).columns.3.xyz
                log(String(format: "map: %@ lands within ±%.1f cm", place.name, refined.uncertainty(at: at) * 100))
            }
            guard var p = ar.installLinked(place, transform: transform) else { return nil }
            p.piece = mapKeeper.current.id
            return p
        }
        memory.update(moved)
        linkedPlaces[piece.id] = Set(moved.map(\.id))
        keyframes.relink(piece: piece.id, into: mapKeeper.current.id, transform: transform)
        let names = moved.map(\.name)
        say(names.isEmpty ? phrases.linkedRoom : phrases.linkedRoom(with: names))
        saveRoomSoon()
    }

    /// Points at every remembered place whose name occurs in `text` and has no cue yet.
    func pointAtNamedPlaces(in text: String, alreadyShown: Set<Int>) {
        let words = " " + Utterance.words(text).joined(separator: " ") + " "
        for (mark, place) in ar.places where !alreadyShown.contains(mark) {
            let name = Utterance.words(place.name).filter { !["the", "a", "de", "het", "een", "my", "mijn"].contains($0) }.joined(separator: " ")
            guard !name.isEmpty, words.contains(" " + name + " ") else { continue }
            log("pointing at remembered place \(place.name)")
            ar.show(.outline(mark: mark))
        }
    }

    func rememberPlace(name: String, mark: Int) {
        guard var place = ar.rememberPlace(name: name, mark: mark) else { return }
        place.piece = mapKeeper.current.id
        log("remembered place: \(name)")
        switch memory.consent {
        case true?:
            memory.add(place)
            saveRoomSoon()
        case nil:
            pendingPlaces.append(place)
            askConsentOnce()
        case false?:
            break
        }
    }

    func rememberLongTerm(_ key: String, _ value: String, source: String) {
        switch memory.consent {
        case true?: memory.remember(key, value, source: source)
        case nil:
            pendingFacts.append((key, value, source))
            askConsentOnce()
        case false?: break
        }
    }

    private func askConsentOnce() {
        guard !awaitingConsent, !consentQueued else { return }
        consentQueued = true
        // After Pip has finished its sentence about what it will remember, and not over the user.
        // Only once the question is asked does a yes or no answer it: an "okay" said before it
        // is no consent to keep camera snapshots for a week.
        Task {
            while speaker.isSpeaking || lookActive || phase == .hearing { try? await Task.sleep(nanoseconds: 200_000_000) }
            consentQueued = false
            guard memory.consent == nil else { return }
            awaitingConsent = true
            say(phrases.askMemory)
        }
    }

    /// The switch in the memory sheet: the same as answering the question.
    func setConsent(_ yes: Bool) {
        awaitingConsent = false
        consentQueued = false
        memory.setConsent(yes)
        mapKeeper.enabled = yes
        if yes {
            keyframes.persist = true
            keyframes.currentPiece = mapKeeper.current.id
            keepPending()
        } else {
            keyframes.stopPersisting()
            pendingPlaces = []
            pendingFacts = []
        }
    }

    private func keepPending() {
        for p in pendingPlaces { memory.add(p) }
        for f in pendingFacts { memory.remember(f.key, f.value, source: f.source) }
        for (key, fact) in facts where memory.facts[key] == nil { memory.remember(key, fact.value, source: fact.source) }
        pendingPlaces = []
        pendingFacts = []
        saveRoomSoon()
    }

    func answerConsent(_ yes: Bool, heard: String) {
        setConsent(yes)
        say(yes ? phrases.memoryYes : phrases.memoryNo, heard: heard)
    }

    /// Saves the room map a moment later, when ARKit has taken in the new anchor.
    func saveRoomSoon() {
        guard memory.consent == true else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.saveRoomNow()
        }
    }

    /// Saves this session's map piece: the room's surfaces, the keyframes, and ARKit's own map
    /// with the places' anchors. The 3D map grows with every session, places or not.
    func saveRoomNow() {
        guard memory.consent == true else { return }
        // Places ARKit brought back now have a known pose in this piece.
        if !ar.restoredPlaces.isEmpty {
            memory.update(ar.restoredPlaces.map { var p = $0; p.piece = mapKeeper.current.id; return p })
            ar.restoredPlaces = []
        }
        // Where on earth this piece is, once it is this session's own (not while ARKit still tries it).
        if let here = homeLocation.point, !ar.awaitingFirstRelocalisation { mapKeeper.setLocation(here) }
        // iOS gives the app a little time in the background to finish writing: until both the
        // map piece and ARKit's own map (which may wait for ARKit and retry) are written.
        let background = BackgroundWork(name: "Pip map", parts: 2)
        mapKeeper.save(mesh: ar.meshRaw()) {
            Task { @MainActor in background.done() }
        }
        keyframes.saveIndex()
        let id = mapKeeper.current.id
        ar.saveMap { [weak self] map, detail in
            if let map { MapStore.saveWorldMap(map, for: id) }
            self?.ar.relocalisation.saved(map != nil, detail: map.map { String(format: "piece %@, %d feature points, %@",
                String(id.uuidString.prefix(4)), $0.rawFeaturePoints.points.count, detail) } ?? detail)
            background.done()
        }
    }

    func forget(place id: UUID) {
        ar.forgetPlace(id)
        memory.remove(id)
        saveRoomSoon()
    }

    func forget(fact key: String) {
        facts[key] = nil
        memory.forget(fact: key)
    }

    /// Places (also this session's), facts, the room map and the visual memory.
    func forgetEverything() {
        ar.forgetAllPlaces()
        keyframes.forgetAll()
        mapKeeper.begin(continuing: nil, others: [])
        // New snapshots belong to the new piece, not to the one just deleted.
        keyframes.currentPiece = mapKeeper.current.id
        facts = [:]
        pendingPlaces = []
        pendingFacts = []
        memory.forgetAll()
    }
}

/// A background task that ends once each of its parts is done, or when iOS's time is up (iOS
/// ends the app if a background task outlives it).
@MainActor
private final class BackgroundWork {
    private var id: UIBackgroundTaskIdentifier = .invalid
    private var left: Int

    init(name: String, parts: Int) {
        left = parts
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func done() {
        left -= 1
        if left == 0 { end() }
    }

    private func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
