import Foundation
import PipCore
import UIKit
import simd

/// "Where did I leave my drink?" from the visual memory, and the shopping list.
extension GuideModel {
    // MARK: Visual memory

    /// Wonder picks where the object was seen; SAM must find it there before Pip points. The last
    /// half hour first, then the week before it, newest first, a contact sheet batch at a time.
    func findInMemory(_ what: String, phrase: String) async {
        // A new find replaces the promise of an earlier one.
        awaitingRoom = nil
        let all = keyframes.frames
        guard let oldest = all.first else {
            say(phrases.notFound(what, since: nil))
            return
        }
        // The banner of a plan being prepared or pages being read comes back afterwards.
        let shownBefore = preparing
        let banner = phrases.searchingMemory(what)
        preparing = banner
        defer { if preparing == banner { preparing = shownBefore } }
        let now = Date()
        let recent = all.filter { now.timeIntervalSince($0.time) <= Keyframes.recentFor }
        let older = all.filter { now.timeIntervalSince($0.time) > Keyframes.recentFor }.reversed()
        let batchSize = MemorySearch.tilesPerSheet * MemorySearch.maxSheets
        var batches: [[Keyframes.Frame]] = recent.isEmpty ? [] : [recent]
        var rest = Array(older)
        while !rest.isEmpty, batches.count < 4 {
            batches.append(Array(rest.prefix(batchSize)).reversed())
            rest = Array(rest.dropFirst(batchSize))
        }
        var elsewhere: Keyframes.Frame?
        for (n, batch) in batches.enumerated() {
            if n == 1 { say(phrases.searchingFurther) }
            let outcome = await search(what, phrase: phrase, in: batch)
            if Task.isCancelled { return }
            if case .found(let world, let frame, let spec) = outcome {
                // A place remembered under this name and brought back here lies there already: it is
                // the same object, and its mark is pointed at (it knows what the object looked like
                // to the model; a second outline from a snapshot of the same session only showed the
                // same link error twice, 2 Nov).
                if let mark = rememberedMark(named: what, near: world) {
                    ar.show(.outline(mark: mark))
                    log("the sighting of \(what) is the remembered place \(ar.places[mark]?.name ?? ""): pointed at that")
                    let place = ar.describe(mark: mark, dutch: language == "Dutch") ?? ""
                    say(phrases.found(what, at: frame.time, where: place.components(separatedBy: ";").first ?? place))
                    return
                }
                foundCount += 1
                let id = ARController.foundMarkBase + foundCount % 90_000
                // Earlier cues give way first: the found object is this answer's.
                ar.giveWay()
                ar.addFound(world: world, id: id, spec: spec)
                ar.show(.outline(mark: id))
                // A place remembered in another map of this room: found here, it is anchored in
                // this room's map from now on, so it is pointed at at once next time.
                if let orphan = orphanPlace(matching: what) { adopt(orphan, mark: id) }
                let place = ar.describe(mark: id, dutch: language == "Dutch") ?? ""
                say(phrases.found(what, at: frame.time, where: place.components(separatedBy: ";").first ?? place))
                return
            }
            // Seen last in a room not recognised here: older batches would only give older places.
            if case .elsewhere(let frame) = outcome {
                elsewhere = frame
                break
            }
        }
        if let elsewhere {
            // Where it was, from the snapshot itself: the room and what it lay on.
            var place: String?
            if let jpeg = elsewhere.jpeg() { place = (try? await MemorySearch(client: client).place(of: what, in: jpeg, language: language)) ?? nil }
            if Task.isCancelled { return }
            if let place { facts["last seen: \(what)"] = Fact(value: "\(place) (\(phrases.ago(elsewhere.time)), in a room not recognised in this session)", source: "seen") }
            say(phrases.foundElsewhere(what, at: elsewhere.time, place: place))
            log("find: \(what) seen \(phrases.ago(elsewhere.time)) in a room not recognised yet; pointed at once it is")
            awaitingRoom = (what, phrase, elsewhere.id, elsewhere.piece, Date())
        } else {
            say(phrases.notFound(what, since: oldest.time))
        }
    }

    /// The room a find saw its thing in is recognised now: Pip points at it, as it said it would
    /// (2 Nov, 18:36: asked in the bathroom 4 s in, the bedroom recognised from the hall 50 s later,
    /// and the pen pointed at only when asked again). By the remembered place of that name that the
    /// link brought back, else by the sighting itself, found again in its snapshot, which can be
    /// placed here now. Not when it is pointed at already, and not over the user or Pip.
    func followUpFind() async {
        guard let pending = awaitingRoom, !followingUp else { return }
        guard Date().timeIntervalSince(pending.asked) < 15 * 60 else {
            awaitingRoom = nil
            return
        }
        // A place of that name of the sighting's session, or one a link brought back: the same thing.
        func score(_ place: SpaceMemory.Place) -> Int { PlaceName.score(pending.what, names: [place.name, place.phrase ?? ""]) }
        let candidates = ar.places.filter { mark, place in
            score(place) > 0 && ((pending.piece != nil && place.piece == pending.piece) || ar.carried.contains(mark))
        }
        var mark = candidates.max { score($0.value) < score($1.value) }?.key
        var name = mark.flatMap { ar.places[$0] }.map { yours($0.name) } ?? pending.what
        followingUp = true
        defer { followingUp = false }
        if mark == nil {
            guard let frame = keyframes.frames.first(where: { $0.id == pending.frame }), frame.located else { return }
            awaitingRoom = nil
            guard case .found(let world, _, let spec) = await search(pending.what, phrase: pending.phrase, in: [frame]) else {
                log("find: \(pending.what): its room is recognised, but it was not found again in the snapshot")
                return
            }
            foundCount += 1
            let id = ARController.foundMarkBase + foundCount % 90_000
            ar.giveWay()
            ar.addFound(world: world, id: id, spec: spec)
            mark = id
            name = pending.what
        }
        awaitingRoom = nil
        guard let mark else { return }
        while speaker.isSpeaking || lookActive || phase == .hearing {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
        }
        guard !ar.board.annotations.contains(where: { $0.cue.marks.contains(mark) }) else {
            log("find: \(pending.what): its room is recognised; pointed at already")
            return
        }
        ar.show(.outline(mark: mark))
        let place = ar.describe(mark: mark, dutch: language == "Dutch") ?? ""
        log("find: \(pending.what): its room is recognised now; pointed at (\(place))")
        say(phrases.recognisedNow(name, where: place.components(separatedBy: ";").first ?? place))
    }

    /// Places that came back with a link, named by the user's question of just before: pointed at, as
    /// the answer it wanted (2 Nov, 19:09: "Where is the book" 22 s in, answered with the books in
    /// view; the one the user had asked Pip to remember came back with the link 2 s later, and was
    /// pointed at only when the user said so). Not when it is pointed at already, and not once the
    /// user asked something else.
    func followUpQuestion(placesBack back: [SpaceMemory.Place]) async {
        guard awaitingRoom == nil, !followingUp, let q = lastQuestion, Date().timeIntervalSince(q.at) < 60 else { return }
        func score(_ p: SpaceMemory.Place) -> Int { PlaceName.score(q.text, names: [p.name, p.phrase ?? ""]) }
        guard let place = back.filter({ score($0) > 0 }).max(by: { score($0) < score($1) }),
              let mark = ar.places.first(where: { $0.value.id == place.id })?.key else { return }
        lastQuestion = nil
        followingUp = true
        defer { followingUp = false }
        while speaker.isSpeaking || lookActive || phase == .hearing {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
        }
        guard lookCount == q.look else { return }
        guard !ar.board.annotations.contains(where: { $0.cue.marks.contains(mark) }) else {
            log("question \"\(q.text)\": \(place.name) came back with the room; pointed at already")
            return
        }
        ar.show(.outline(mark: mark))
        let at = ar.describe(mark: mark, dutch: language == "Dutch") ?? ""
        log("question \"\(q.text)\": \(place.name) came back with the room; pointed at (\(at))")
        say(phrases.recognisedNow(yours(place.name), where: at.components(separatedBy: ";").first ?? at))
    }

    /// "your notebook" for a place named "the notebook", in the conversation's language.
    func yours(_ name: String) -> String {
        let dutch = language == "Dutch"
        var bare = name
        for article in ["the ", "The ", "de ", "De ", "het ", "Het ", "mijn ", "Mijn ", "my ", "My "] where bare.hasPrefix(article) {
            bare = String(bare.dropFirst(article.count))
            break
        }
        return (dutch ? "je " : "your ") + bare
    }

    enum Recall {
        case found(world: [[simd_float3]], frame: Keyframes.Frame, spec: TargetSpec)
        /// Seen, but in a room this session has not recognised (its place is unknown here).
        case elsewhere(Keyframes.Frame)
        case none
    }

    /// One batch of snapshots: Wonder finds the object on contact sheets; each sighting is then
    /// pinpointed in its own snapshot at full resolution and outlined like a question's target
    /// (the contact sheet's point can be far off: on 1 Nov on the carpet beside the statue's table),
    /// with depth to place it in the room. Nothing is pointed at on a guess.
    func search(_ what: String, phrase: String, in batch: [Keyframes.Frame]) async -> Recall {
        // Only snapshots that can still be read; their order is kept for the mapping back.
        let readable = batch.compactMap { f in f.jpeg().map { (f, $0) } }
        let t0 = Date()
        let sightings = (try? await MemorySearch(client: client).find(what, in: readable.map(\.1))) ?? []
        if Task.isCancelled { return .none }
        log(String(format: "memory search %.1fs over %d snapshots: %d sightings", Date().timeIntervalSince(t0), readable.count, sightings.count))
        for s in sightings where readable.indices.contains(s.index) {
            let frame = readable[s.index].0
            let jpeg = readable[s.index].1
            guard frame.located else {
                // Seen in a room this session has not recognised (its session is not linked): said,
                // when, not where. The newest sighting is where the thing is, so an older one is not
                // pointed at instead; confirmed in its own snapshot first, like a pointed-at one.
                if (try? await MemorySearch(client: client).pinpoint(what, in: jpeg)) != nil { return .elsewhere(frame) }
                if Task.isCancelled { return .none }
                log("sighting elsewhere not confirmed (not found again in the snapshot)")
                continue
            }
            guard let image = UIImage(data: jpeg)?.cgImage else { continue }
            guard let pin = try? await MemorySearch(client: client).pinpoint(what, in: jpeg) else {
                if Task.isCancelled { return .none }
                log("sighting not confirmed (not found again in the snapshot)")
                continue
            }
            let point = CGPoint(x: pin.x / 1000 * Double(frame.width), y: pin.y / 1000 * Double(frame.height))
            let spec = TargetSpec(x: pin.x, y: pin.y, phrase: pin.noun.isEmpty ? (phrase.isEmpty ? "object" : phrase) : pin.noun)
            let grounded = await Grounder(client: client, frameJPEG: jpeg).ground(spec, id: 1, frame: image, describe: { what })
            if Task.isCancelled { return .none }
            guard let inst = grounded.instance, Double(inst.area) <= 0.3 * Double(image.width * image.height),
                  let depth = frame.depth(atPixel: inst.centre) ?? frame.depth(atPixel: point) else {
                log("sighting not confirmed (\(grounded.method))")
                continue
            }
            log("sighting confirmed (\(grounded.method))")
            let world = inst.regularized().outlinePoints.map { ring in ring.map { frame.worldPoint(atPixel: $0, depth: depth) } }
            // Found again on sight by the user's words for it (see `ARController.carried`).
            return .found(world: world, frame: frame, spec: TargetSpec(x: 500, y: 500, phrase: spec.phrase, text: spec.text, description: what))
        }
        return .none
    }

    /// The mark of a remembered place that `what` names and that lies within half a metre of an
    /// outline found in the visual memory: the same object.
    func rememberedMark(named what: String, near world: [[simd_float3]]) -> Int? {
        let points = world.flatMap { $0 }
        guard !points.isEmpty else { return nil }
        let centre = points.reduce(simd_float3.zero, +) / Float(points.count)
        return ar.places.filter { mark, place in
            PlaceName.score(what, names: [place.name, place.phrase ?? ""]) > 0
                && (ar.marks[mark].map { simd_distance($0.centroid, centre) < 0.5 } ?? false)
        }.min { a, b in
            simd_distance(ar.marks[a.key]!.centroid, centre) < simd_distance(ar.marks[b.key]!.centroid, centre)
        }?.key
    }

    // MARK: Places of other maps of this room

    /// A remembered place of another map piece (this room mapped in another session, not linked)
    /// that `what` names: "the user's gold statue" for "taller golden statue", never a table for a
    /// tablet (see PlaceName: the found object takes the place over).
    func orphanPlace(matching what: String) -> SpaceMemory.Place? {
        let here = Set(ar.places.values.map(\.id))
        let orphans = memory.places.filter { $0.piece != mapKeeper.current.id && !here.contains($0.id) }
        func score(_ p: SpaceMemory.Place) -> Int { PlaceName.score(what, names: [p.name, p.phrase ?? ""]) }
        return orphans.filter { score($0) > 0 }.max { score($0) < score($1) }
    }

    /// Re-anchors a place of another map in this one, where `mark` found it. The new place replaces
    /// the old one (same name) only once it exists: on 1 Nov the old one was removed first and the
    /// new one could not be made, and the place was lost.
    func adopt(_ place: SpaceMemory.Place, mark: Int) {
        if rememberPlace(name: place.name, mark: mark) {
            log("place \(place.name): found again in this room; anchored in its map from now on")
        } else {
            log("place \(place.name): found again, but could not be anchored here; kept as it was")
        }
    }

    // MARK: Shopping list

    func updateList(add: [String], got: [String], remove: [String]) {
        listChangedAt = Date()
        for item in add where !shopping.contains(where: { $0.name.lowercased() == item.lowercased() }) {
            shopping.append(ShoppingItem(name: item))
        }
        for item in got {
            if let i = shopping.firstIndex(where: { $0.name.lowercased() == item.lowercased() }) { shopping[i].inBasket = true }
        }
        shopping.removeAll { item in remove.contains { $0.lowercased() == item.name.lowercased() } }
    }

    /// Basket checks stop this long after the list last changed.
    static let basketQuietAfter: TimeInterval = 15 * 60

    func startBasketWatch() {
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.basketTick() }
        }
    }

    /// Ticks items off once they are seen in the basket twice in a row; warns about a wrong variant
    /// seen twice in a row.
    private func basketTick() async {
        let needed = shopping.filter { !$0.inBasket }.map(\.name)
        // Checks stop after a quiet spell (the user stopped shopping); any list change restarts them.
        guard !needed.isEmpty, Date().timeIntervalSince(listChangedAt) < Self.basketQuietAfter,
              !basketChecking, !lookActive, !speaker.isSpeaking, phase != .hearing, !muted,
              ar.trackingNormal, let snapshot = ar.snapshot() else { return }
        basketChecking = true
        defer { basketChecking = false }
        guard let result = try? await BasketChecker(client: client).check(snapshot.image, needed: needed) else { return }
        // The user or Pip started talking meanwhile: this check is not spoken over them.
        guard !lookActive, !speaker.isSpeaking, phase != .hearing else { return }
        log("basket: \(result.inBasket) wrong: \(result.wrong.map { "\($0.item)≠\($0.seen)" })")
        var spoken: [String] = []
        for i in shopping.indices where !shopping[i].inBasket {
            let name = shopping[i].name
            if result.inBasket.contains(where: { $0.lowercased() == name.lowercased() }) {
                shopping[i].hits += 1
                if shopping[i].hits >= 2 {
                    shopping[i].inBasket = true
                    listChangedAt = Date()
                    spoken.append(phrases.gotItem(name))
                }
            } else {
                shopping[i].hits = 0
            }
            if let wrong = result.wrong.first(where: { $0.item.lowercased() == name.lowercased() }) {
                shopping[i].wrongHits += 1
                if shopping[i].wrongHits == 2 { spoken.append(phrases.wrongItem(name, seen: wrong.seen)) }
            } else {
                shopping[i].wrongHits = 0
            }
        }
        for line in spoken { say(line) }
        if !spoken.isEmpty, shopping.allSatisfy(\.inBasket) { say(phrases.listComplete) }
    }
}
