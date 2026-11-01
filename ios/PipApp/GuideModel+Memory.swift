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
        savedPieces = saved
        ar.relocalisation.onStatus = { [weak self] s in self?.ar.setStatusLine("map", s) }
        // The location can come in a second or two after start: a room from elsewhere is given up then.
        homeLocation.onUpdate = { [weak self] here in self?.locationArrived(here) }
        ar.relocalisation.onHint = { [weak self] hint in self?.mappingHint(hint) }
        ar.relocalisation.trying(continuing.map { String($0.id.uuidString.prefix(4)) }, detail: continuing.map(describe) ?? "\(pieces.count) pieces stored")
        mapKeeper.enabled = memory.consent == true
        mapKeeper.begin(continuing: continuing, others: pieces.filter { $0.id != continuing?.id })
        mapKeeper.onLog = { [weak self] line in self?.log(line) }
        ar.onRelocaliseGaveUp = { [weak self] in self?.relocalisationGaveUp() }
        ar.restartHold = { [weak self] in self?.lookActive ?? false }
        ar.onStartedAfresh = { [weak self] carried in
            Task { @MainActor [weak self] in await self?.findAgain(carried) }
        }
        // Recognised: places remembered in other maps of this room are looked for here, quietly,
        // once Pip is free (see adoptPlacesOfThisRoom).
        ar.onRecognised = { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await self?.adoptPlacesOfThisRoom()
            }
        }
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
        ar.start(initialMap: worldMap)
        // Once ARKit has measured the light: if another saved room was mapped in light much more
        // like now's, it is tried instead, at once (one switch; maps are not cycled every few seconds).
        if let tried = continuing, savedPieces.count > 1 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.preferSameLight(over: tried)
            }
        }
        // The week's snapshots: those of the room ARKit is recognising can be pointed at.
        keyframes.persist = memory.consent == true
        keyframes.currentPiece = mapKeeper.current.id
        keyframes.load(locatedPiece: continuing?.id)
        // Places of the piece ARKit is recognising come back on their own anchors.
        ar.restore(memory.places.filter { $0.piece == nil || $0.piece == continuing?.id })
        if continuing != nil { log("map: recognising the room of last time") }
        Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.mapKeeper.dirty else { return }
                self.saveRoomNow()
            }
        }
    }

    /// The saved room whose light is most like now's, among the one being tried and the others:
    /// switched to when it is clearly closer (by 0.8: a third brighter and 700 K, or so).
    private func preferSameLight(over tried: MapPiece) {
        guard ar.awaitingFirstRelocalisation, let now = ar.currentLight else { return }
        func distance(_ p: MapPiece) -> Double { p.light.map { $0.distance(to: now) } ?? 1 }
        // Any saved room of here, not only the next ones in line; among those in the same light,
        // the one updated last.
        let rivals = savedPieces.filter { $0.id != tried.id && $0.keyframes.count >= 10 }
        guard let best = rivals.min(by: { distance($0) != distance($1) ? distance($0) < distance($1) : $0.updated > $1.updated }),
              distance(best) + 0.8 < distance(tried),
              let map = usableMap(best) else {
            Relocalisation.log(String(format: "light now %.0f lm, %.0f K; trying piece %@ (its light %@)", now.intensity, now.temperature,
                                      String(tried.id.uuidString.prefix(4)), tried.light.map { String(format: "%.0f lm, %.0f K", $0.intensity, $0.temperature) } ?? "unknown"))
            return
        }
        log(String(format: "map: the light now (%.0f lm, %.0f K) is closer to that of piece %@; trying it first", now.intensity, now.temperature, String(best.id.uuidString.prefix(4))))
        mapCandidates.removeAll { $0.id == best.id }
        mapCandidates.insert(tried, at: 0)
        ar.restart(initialMap: map)
        let others = mapKeeper.others.filter { $0.id != best.id } + (mapKeeper.current.keyframes.isEmpty ? [] : [mapKeeper.current])
        mapKeeper.begin(continuing: best, others: others)
        keyframes.locate(best.id)
        ar.restore(memory.places.filter { $0.piece == nil || $0.piece == best.id })
        ar.relocalisation.trying(String(best.id.uuidString.prefix(4)), detail: describe(best) + " (closer light)")
    }

    /// No more saved rooms are tried this session (`reason`: why, for the log).
    func giveUpRecognising(because reason: String) {
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

    /// Tracking started afresh (the saved room was given up) while these objects were pointed at:
    /// each is found again in the new session, from what the model asked for, around where it was
    /// on screen, so its cue goes on its object again and it is locked to it again.
    func findAgain(_ carried: [ARController.Carried]) async {
        // Tracking needs a moment to start (up to 5 s).
        var waited = 0.0
        repeat {
            try? await Task.sleep(nanoseconds: 250_000_000)
            waited += 0.25
        } while !ar.cameraPoseUsable && waited < 5
        guard ar.cameraPoseUsable, let snapshot = ar.snapshot() else {
            log("map: started afresh; tracking not back, \(carried.count) outlines not found again")
            return
        }
        let grounder = Grounder(client: client, frameJPEG: SetOfMarks.jpeg(snapshot.image, quality: 0.8) ?? Data())
        let found = await withTaskGroup(of: (ARController.Carried, SegmentInstance?).self) { group -> [(ARController.Carried, SegmentInstance?)] in
            for c in carried {
                group.addTask { (c, await grounder.ground(c.spec, id: c.id, frame: snapshot.image).instance) }
            }
            var out: [(ARController.Carried, SegmentInstance?)] = []
            for await r in group { out.append(r) }
            return out
        }
        for (c, inst) in found.sorted(by: { $0.0.id < $1.0.id }) {
            guard let inst else {
                log("mark \(c.id % 1000) not found again after the fresh start")
                continue
            }
            let key = inst.renumbered(c.id)
            let anchoring = ar.addMark(key, snapshot: snapshot, spec: c.spec)
            if anchoring != "assumed depth" { lockToObject(c.id, key: key, on: c.spec.on, snapshot: snapshot) }
            log("mark \(c.id % 1000) found again after the fresh start, anchored on \(anchoring)")
        }
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
            homeLocation.start()
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

    /// Saves this session's map piece: the keyframes, location and light, and ARKit's own map
    /// with the places' anchors. The 3D map grows with every session, places or not.
    func saveRoomNow() {
        guard memory.consent == true else { return }
        // Places ARKit brought back now have a known pose in this piece.
        if !ar.restoredPlaces.isEmpty {
            memory.update(ar.restoredPlaces.map { var p = $0; p.piece = mapKeeper.current.id; return p })
            ar.restoredPlaces = []
        }
        // Where on earth this piece is, once it is this session's own (not while ARKit still tries it),
        // and the light it is mapped in.
        if let here = homeLocation.point, !ar.awaitingFirstRelocalisation { mapKeeper.setLocation(here) }
        if let light = ar.currentLight, !ar.awaitingFirstRelocalisation { mapKeeper.setLight(light) }
        // iOS gives the app a little time in the background to finish writing: until both the
        // map piece and ARKit's own map (which may wait for ARKit and retry) are written.
        let background = BackgroundWork(name: "Pip map", parts: 2)
        mapKeeper.save {
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

    /// Places (also this session's), facts, the room map, the visual memory and the test record.
    func forgetEverything() {
        Diagnostics.removeAll()
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
