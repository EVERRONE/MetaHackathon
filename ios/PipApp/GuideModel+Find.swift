import Foundation
import PipCore
import UIKit

/// "Where did I leave my drink?" from the visual memory, and the shopping list.
extension GuideModel {
    // MARK: Visual memory

    /// Wonder picks where the object was seen; SAM must find it there before Pip points. The last
    /// half hour first, then the week before it, newest first, a contact sheet batch at a time.
    func findInMemory(_ what: String, phrase: String) async {
        let all = keyframes.frames
        guard let oldest = all.first else {
            say(phrases.notFound(what, since: nil))
            return
        }
        preparing = phrases.searchingMemory(what)
        defer { preparing = nil }
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
        let grounder = Grounder(client: client, frameJPEG: Data())
        var elsewhere: Keyframes.Frame?
        for (n, batch) in batches.enumerated() {
            if n == 1 { say(phrases.searchingFurther) }
            // Only snapshots that can still be read; their order is kept for the mapping back.
            let readable = batch.compactMap { f in f.jpeg().map { (f, $0) } }
            let t0 = Date()
            let sightings = (try? await MemorySearch(client: client).find(what, in: readable.map(\.1))) ?? []
            if Task.isCancelled { return }
            log(String(format: "memory search %.1fs over %d snapshots: %d sightings", Date().timeIntervalSince(t0), readable.count, sightings.count))
            for s in sightings where readable.indices.contains(s.index) {
                let frame = readable[s.index].0
                guard frame.located else {
                    // Seen in a room this session has not recognised yet: say when, not where.
                    elsewhere = elsewhere ?? frame
                    continue
                }
                guard let image = UIImage(data: readable[s.index].1)?.cgImage else { continue }
                let point = CGPoint(x: s.x / 1000 * Double(frame.width), y: s.y / 1000 * Double(frame.height))
                // Confirmation: SAM has to find that kind of object there (not just anything), with
                // depth to place it in the room.
                let confirmed = phrase.isEmpty ? await grounder.object(at: point, in: image, id: 1)
                    : await grounder.object(named: phrase, at: point, in: image, id: 1)
                if Task.isCancelled { return }
                guard let inst = confirmed, let depth = frame.depth(atPixel: inst.centre) ?? frame.depth(atPixel: point) else {
                    log("sighting not confirmed")
                    continue
                }
                let world = inst.regularized().outlinePoints.map { ring in ring.map { frame.worldPoint(atPixel: $0, depth: depth) } }
                foundCount += 1
                let id = ARController.foundMarkBase + foundCount % 90_000
                ar.addFound(world: world, id: id)
                ar.show(.outline(mark: id))
                let place = ar.describe(mark: id, dutch: language == "Dutch") ?? ""
                say(phrases.found(what, at: frame.time, where: place.components(separatedBy: ";").first ?? place))
                return
            }
        }
        if let elsewhere {
            say(phrases.foundElsewhere(what, at: elsewhere.time))
        } else {
            say(phrases.notFound(what, since: oldest.time))
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
        basketTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
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
