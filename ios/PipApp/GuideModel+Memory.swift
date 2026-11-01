import ARKit
import Foundation
import UIKit
import PipCore
import simd

/// Long-term memory: places in the room and facts about the user's devices, kept across sessions
/// only after the user said yes, and only on this iPhone.
extension GuideModel {
    // MARK: The map of the home

    /// At launch, without the user doing anything: tracking starts fresh, in a map piece of this
    /// session's own (1 Nov: ARKit recognising a saved room kept tracking in its relocalising state
    /// for up to 45 s and restarted it twice, which moved outlines a key or three and dropped them;
    /// it recognised the room once in about ten tries). The maps and snapshots of every session are
    /// kept, and earlier sessions are linked to this one by what they saw (SpaceLinker), without
    /// touching the live session.
    func startMap() {
        memory.migrateLegacyMap()
        let pieces = memory.consent == true ? MapStore.loadAll() : []
        // Only sessions that can be here: one made in another home or building is not linked to (the
        // phone's rough location; pieces without one are kept).
        if memory.consent == true { homeLocation.start() }
        let here = homeLocation.point
        if let here {
            let far = pieces.filter { p in p.location.map { !here.couldBeSamePlace(as: $0) } ?? false }
            if let nearest = far.compactMap({ $0.location?.distance(to: here) }).min() {
                Relocalisation.log(String(format: "location: %d of %d saved pieces are elsewhere (the nearest %.1f km away), not linked to", far.count, pieces.count, nearest / 1000))
            }
        }
        ar.relocalisation.onStatus = { [weak self] s in self?.ar.setStatusLine("map", s) }
        // The location can come in a second or two after start: sessions from elsewhere are dropped then.
        homeLocation.onUpdate = { [weak self] here in self?.locationArrived(here) }
        ar.relocalisation.onHint = { [weak self] hint in self?.mappingHint(hint) }
        ar.relocalisation.started(detail: "\(pieces.count) pieces stored")
        mapKeeper.enabled = memory.consent == true
        mapKeeper.begin()
        mapKeeper.onLog = { [weak self] line in self?.log(line) }
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
        ar.start()
        // The week's snapshots: those of earlier sessions can be pointed at once their session is linked.
        keyframes.persist = memory.consent == true
        keyframes.currentPiece = mapKeeper.current.id
        keyframes.load()
        // Earlier sessions are linked to this one by what they saw, in the background.
        spaceLinker.onLog = { [weak self] line in
            self?.log(line)
            Relocalisation.log(line)
        }
        spaceLinker.onChange = { [weak self] piece, change in self?.spaceLinked(piece, change) }
        spaceLinker.onStatus = { [weak self] line in self?.ar.setStatusLine("space", line) }
        let current = mapKeeper.current.id
        homeGraph = HomeGraphStore.load()
        spaceLinker.begin(with: keyframes.frames.filter { $0.piece != nil && $0.piece != current })
        if let here {
            let locations = Dictionary(uniqueKeysWithValues: pieces.map { ($0.id, $0.location) })
            spaceLinker.keepOnly { piece in (locations[piece] ?? nil).map { here.couldBeSamePlace(as: $0) } ?? true }
        }
        Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.mapKeeper.dirty else { return }
                self.saveRoomNow()
            }
        }
    }

    // MARK: Earlier sessions (SpaceLinker)

    /// An earlier session is linked to this one: its snapshots can be searched and pointed at in this
    /// room (each carried by the links nearest to what it saw), and its remembered places come back
    /// on anchors of their own, where the links carry them; they are found again on sight before
    /// their new position is stored.
    func spaceLinked(_ piece: UUID, _ change: LinkBook.Change) {
        // More evidence carries the snapshots a little better: at most every 5 s.
        if change == .strengthened {
            guard Date().timeIntervalSince(lastCarried[piece] ?? .distantPast) >= 5 else { return }
        }
        lastCarried[piece] = Date()
        let linker = spaceLinker
        let live = mapKeeper.current.id
        // The link joins the two sessions in the home graph (its strongest view link), unless it
        // disagrees with a chain already joining them.
        if let link = linker.linked[piece], let best = link.core.max(by: { $0.inliers < $1.inliers }) {
            // Linked afresh after this session's tracking broke: its coordinates may have moved, by
            // about as much as the fresh link differs from the old one. When by more than a loop may
            // disagree, every link of this session from before the break is stale, not only this
            // pair's: one of them would refuse the fresh links as a loop that disagrees.
            if change == .relinked {
                if let old = homeGraph.link(from: piece, to: live), let broke = linker.lastBreak,
                   old.transform.distance(to: best.transform, at: best.centre) > HomeGraph.loopTolerance
                    || old.transform.turn(to: best.transform) > HomeGraph.loopTurn {
                    homeGraph.removeLinks(of: live, madeBefore: broke)
                    log("space: the tracking break moved this session's coordinates; its links from before it are dropped")
                }
                homeGraph.removeLink(between: piece, and: live)
            }
            let edge = HomeGraph.Edge(from: piece, to: live, transform: best.transform, matches: link.matches, views: link.views, centre: best.centre)
            switch homeGraph.add(edge) {
            case .joined, .replaced:
                if memory.consent == true { HomeGraphStore.save(homeGraph) }
            case .refused(let apart):
                log(String(format: "space: the link to %@ disagrees with the home's other links by %.0f cm; not kept in the home graph",
                           String(piece.uuidString.prefix(4)), apart * 100))
            case .weaker:
                break
            }
        }
        // The linked session's snapshots, by its own links (nearest evidence); every other session
        // joined to it in the home graph through the strongest chain, unless it is linked here itself:
        // then it keeps the carry of its own links, which hold best near their evidence (one rigid
        // chain is centimetres coarser away from the strongest view link).
        var n = keyframes.carry(piece) { linker.carriedPose(of: $0) }
        let direct = Set(linker.linked.keys)
        let through = homeGraph.component(of: live).subtracting([live, piece]).subtracting(direct)
        var chains: [UUID: UprightTransform] = [:]
        for q in through {
            guard let t = homeGraph.transform(from: q, to: live) else { continue }
            chains[q] = t
            n += keyframes.carry(q) { t.matrix * $0.storedPose }
        }
        // Places of all of them come back, each once, on an anchor of its own (ARKit keeps those with
        // this session's map from then on); each is stored again only when found on sight.
        let here = Set(ar.places.values.map(\.id))
        var back: [String] = []
        for place in memory.places where !here.contains(place.id) {
            guard let from = place.piece, let pose = place.pose.map(ARController.matrix) else { continue }
            let carried = direct.contains(from) ? linker.carry(anchor: pose, of: from) : chains[from].map { $0.matrix * pose }
            guard let carried else { continue }
            ar.restoreLinked(place, at: carried)
            back.append(place.name)
        }
        if change != .strengthened || !back.isEmpty {
            log("space: \(n) snapshots of \(1 + chains.count) earlier session\(chains.isEmpty ? "" : "s") can be pointed at here"
                + (chains.isEmpty ? "" : " (\(chains.count) through the home graph)") + (back.isEmpty ? "" : "; places back: \(back.joined(separator: ", "))"))
        }
    }

    /// A fix came in: kept with this piece.
    private func locationArrived(_ here: GeoPoint) {
        mapKeeper.setLocation(here)
        // Earlier sessions mapped elsewhere on earth are not linked to.
        let locations = Dictionary(uniqueKeysWithValues: MapStore.loadAll().map { ($0.id, $0.location) })
        spaceLinker.keepOnly { piece in (locations[piece] ?? nil).map { here.couldBeSamePlace(as: $0) } ?? true }
    }

    /// The mapping needs the user's help: said once in a while (each at most every three minutes),
    /// only when Pip is free.
    func mappingHint(_ hint: Relocalisation.Hint) {
        let key = "\(hint)"
        if let last = hintSaid[key], Date().timeIntervalSince(last) < 180 { return }
        guard !speaker.isSpeaking, !lookActive, phase == .listening else { return }
        hintSaid[key] = Date()
        log("map hint: \(key)")
        switch hint {
        case .moveSlower: say(phrases.moveSlower)
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

    /// Returns whether the place was made (the mark is there to anchor it on).
    @discardableResult
    func rememberPlace(name: String, mark: Int) -> Bool {
        guard var place = ar.rememberPlace(name: name, mark: mark) else { return false }
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
        return true
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
            forgetEarlierSessions()
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
        // Where on earth this piece is, and the light it is mapped in.
        if let here = homeLocation.point { mapKeeper.setLocation(here) }
        if let light = ar.currentLight { mapKeeper.setLight(light) }
        // iOS gives the app a little time in the background to finish writing: until both the
        // map piece and ARKit's own map (which may wait for ARKit and retry) are written.
        let background = BackgroundWork(name: "Pip map", parts: 2)
        mapKeeper.save {
            Task { @MainActor in background.done() }
        }
        keyframes.saveIndex()
        let id = mapKeeper.current.id
        ar.saveMap { [weak self] map, detail in
            // Everything was forgotten while ARKit made the map (up to 15 s): a new piece began, and
            // the forgotten one's map is not written after all.
            guard let self, self.mapKeeper.current.id == id else { background.done(); return }
            if let map { MapStore.saveWorldMap(map, for: id) }
            self.ar.relocalisation.saved(map != nil, detail: map.map { String(format: "piece %@, %d feature points, %@",
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
        mapKeeper.begin()
        // New snapshots belong to the new piece, not to the one just deleted.
        keyframes.currentPiece = mapKeeper.current.id
        facts = [:]
        pendingPlaces = []
        pendingFacts = []
        forgetEarlierSessions()
        memory.forgetAll()
    }

    /// The earlier sessions are forgotten (their snapshots and maps go with the memory): no more
    /// linking to them, and no home graph, which a link made after this would write again.
    private func forgetEarlierSessions() {
        spaceLinker.begin(with: [])
        lastCarried = [:]
        homeGraph = HomeGraph()
        HomeGraphStore.remove()
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
