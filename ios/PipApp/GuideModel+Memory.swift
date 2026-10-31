import Foundation
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
        let recent = pieces.max { $0.updated < $1.updated }
        let worldMap = recent.flatMap { MapStore.loadWorldMap($0.id) }
        let continuing = worldMap != nil ? recent : nil
        mapKeeper.enabled = memory.consent == true
        mapKeeper.begin(continuing: continuing, others: pieces.filter { $0.id != continuing?.id })
        mapKeeper.onLog = { [weak self] line in self?.log(line) }
        mapKeeper.onLink = { [weak self] piece, refined, transform in self?.linked(piece, refined: refined, transform: transform) }
        ar.onRelocaliseGaveUp = { [weak self] in self?.relocalisationGaveUp() }
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

    private func relocalisationGaveUp() {
        log("map: not the room of last time; starting a new piece")
        ar.restartFresh()
        mapKeeper.startNewPiece()
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
        let names = moved.map(\.name)
        say(names.isEmpty ? phrases.linkedRoom : phrases.linkedRoom(with: names))
        saveRoomSoon()
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
        guard !awaitingConsent else { return }
        awaitingConsent = true
        // After Pip has finished its sentence about what it will remember, and not over the user.
        Task {
            while speaker.isSpeaking || lookActive || phase == .hearing { try? await Task.sleep(nanoseconds: 200_000_000) }
            guard awaitingConsent, memory.consent == nil else { return }
            say(phrases.askMemory)
        }
    }

    /// The switch in the memory sheet: the same as answering the question.
    func setConsent(_ yes: Bool) {
        awaitingConsent = false
        memory.setConsent(yes)
        mapKeeper.enabled = yes
        if yes { keepPending() } else { pendingPlaces = []; pendingFacts = [] }
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
        mapKeeper.save(mesh: ar.meshPoints())
        let id = mapKeeper.current.id
        ar.saveMap { map in MapStore.saveWorldMap(map, for: id) }
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
        facts = [:]
        pendingPlaces = []
        pendingFacts = []
        memory.forgetAll()
    }
}
