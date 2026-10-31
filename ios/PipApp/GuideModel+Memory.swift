import Foundation
import UIKit
import PipCore
import simd

/// Long-term memory: places in the room and facts about the user's devices, kept across sessions
/// only after the user said yes, and only on this iPhone.
extension GuideModel {
    // MARK: The map of the home

    /// At launch: the most recently used map piece is handed to ARKit, which recognises the room
    /// within seconds if Pip is in it (its places come back on their anchors). If not, Pip starts a
    /// fresh piece, and every stored piece waits to be recognised and linked while the user walks.
    func startMap() {
        memory.migrateLegacyMap()
        let pieces = memory.consent == true ? MapStore.loadAll() : []
        // Spike T3: the one home map instead of the latest piece's (see MapTest).
        let test = MapTest.enabled ? MapTest() : nil
        let recent = test == nil ? pieces.max { $0.updated < $1.updated } : nil
        let worldMap = test?.homeMap ?? recent.flatMap { MapStore.loadWorldMap($0.id) }
        let continuing = worldMap != nil ? recent : nil
        if let test {
            ar.mapTest = test
            ar.keepRelocalising = test.homeMap != nil
            test.onStatus = { [weak self] s in self?.ar.setSpikeStatus("map", s) }
            log(test.homeMap != nil ? "map test: recognising the home map" : "map test: no home map yet")
        }
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
        // Places of the piece ARKit is recognising come back on their own anchors (with the home
        // map: every place whose anchor it holds).
        ar.restore(test != nil ? memory.places : memory.places.filter { $0.piece == nil || $0.piece == continuing?.id })
        if continuing != nil { log("map: recognising the room of last time") }
        mapSaveTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.mapKeeper.dirty else { return }
                self.saveRoomNow()
            }
        }
    }

    private func relocalisationGaveUp() {
        log("map: not the room of last time; starting a new piece")
        ar.restartFresh()
        mapKeeper.startNewPiece()
        keyframes.pieceChanged(to: mapKeeper.current.id)
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
        // iOS gives the app a little time in the background to finish writing: until both the
        // map piece and ARKit's own map (which may wait for ARKit and retry) are written.
        let background = BackgroundWork(name: "Pip map", parts: 2)
        mapKeeper.save(mesh: ar.meshRaw()) {
            Task { @MainActor in background.done() }
        }
        keyframes.saveIndex()
        let id = mapKeeper.current.id
        ar.saveMap { map in
            if let map { MapStore.saveWorldMap(map, for: id) }
            background.done()
        }
    }

    /// The map test's home map (see MapTest): on the button in the memory sheet, and when the app
    /// goes to the background. Saved only when ARKit mapped the area and recognised the home map.
    func saveHomeMap(reason: String) {
        guard let test = ar.mapTest else { return }
        let background = BackgroundWork(name: "Pip home map", parts: 1)
        test.save(ar, reason: reason) { [weak self] message in
            MapTest.log("save (\(reason)): \(message)")
            Task { @MainActor in
                self?.ar.setSpikeStatus("mapsave", message)
                self?.log("map test: \(message)")
                background.done()
            }
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
