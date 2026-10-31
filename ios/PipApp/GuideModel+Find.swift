import Foundation
import PipCore
import UIKit

/// "Where did I leave my drink?" from the visual memory, and the shopping list.
extension GuideModel {
    // MARK: Visual memory

    /// Wonder picks where the object was seen; SAM must find it there before Pip points.
    func findInMemory(_ what: String, phrase: String) async {
        let frames = keyframes.frames
        let minutes = Int((frames.first.map { Date().timeIntervalSince($0.time) } ?? 0) / 60)
        guard !frames.isEmpty else {
            say(phrases.notFound(what, minutes: 0))
            return
        }
        preparing = phrases.searchingMemory(what)
        defer { preparing = nil }
        let t0 = Date()
        let sightings = (try? await MemorySearch(client: client).find(what, in: frames.map(\.jpeg))) ?? []
        log(String(format: "memory search %.1fs over %d snapshots: %d sightings", Date().timeIntervalSince(t0), frames.count, sightings.count))
        let grounder = Grounder(client: client, frameJPEG: Data())
        for s in sightings where frames.indices.contains(s.index) {
            let frame = frames[s.index]
            guard let image = UIImage(data: frame.jpeg)?.cgImage else { continue }
            let point = CGPoint(x: s.x / 1000 * Double(frame.width), y: s.y / 1000 * Double(frame.height))
            // Confirmation: SAM has to find an object there, with depth to place it in the room.
            guard let inst = await grounder.object(at: point, in: image, id: 1),
                  let depth = frame.depth(atPixel: inst.centre) ?? frame.depth(atPixel: point) else {
                log("sighting in snapshot \(frame.id) not confirmed")
                continue
            }
            let world = inst.regularized().outlinePoints.map { ring in ring.map { frame.worldPoint(atPixel: $0, depth: depth) } }
            foundCount += 1
            let id = 800_000 + foundCount
            ar.addFound(world: world, id: id)
            ar.show(.outline(mark: id))
            let ago = Int(Date().timeIntervalSince(frame.time) / 60)
            let place = ar.describe(mark: id, dutch: language == "Dutch") ?? ""
            say(phrases.found(what, minutes: ago, where: place.components(separatedBy: ";").first ?? place))
            return
        }
        say(phrases.notFound(what, minutes: minutes))
    }

    // MARK: Shopping list

    func updateList(add: [String], got: [String], remove: [String]) {
        for item in add where !shopping.contains(where: { $0.name.lowercased() == item.lowercased() }) {
            shopping.append(ShoppingItem(name: item))
        }
        for item in got {
            if let i = shopping.firstIndex(where: { $0.name.lowercased() == item.lowercased() }) { shopping[i].inBasket = true }
        }
        shopping.removeAll { item in remove.contains { $0.lowercased() == item.name.lowercased() } }
    }

    func startBasketWatch() {
        basketTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.basketTick() }
        }
    }

    /// Ticks items off once they are seen in the basket twice in a row; warns about a wrong variant
    /// seen twice in a row.
    private func basketTick() async {
        let needed = shopping.filter { !$0.inBasket }.map(\.name)
        guard !needed.isEmpty, !basketChecking, !lookActive, !speaker.isSpeaking, phase != .hearing, !muted,
              ar.trackingNormal, let snapshot = ar.snapshot() else { return }
        basketChecking = true
        defer { basketChecking = false }
        guard let result = try? await BasketChecker(client: client).check(snapshot.image, needed: needed) else { return }
        log("basket: \(result.inBasket) wrong: \(result.wrong.map { "\($0.item)≠\($0.seen)" })")
        var spoken: [String] = []
        for i in shopping.indices where !shopping[i].inBasket {
            let name = shopping[i].name
            if result.inBasket.contains(where: { $0.lowercased() == name.lowercased() }) {
                shopping[i].hits += 1
                if shopping[i].hits >= 2 {
                    shopping[i].inBasket = true
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
