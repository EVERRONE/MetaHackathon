import Foundation
import PipCore

/// Long-term memory: places in the room and facts about the user's devices, kept across sessions
/// only after the user said yes, and only on this iPhone.
extension GuideModel {
    func rememberPlace(name: String, mark: Int) {
        guard let place = ar.rememberPlace(name: name, mark: mark) else { return }
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
        // After Pip has finished its sentence about what it will remember.
        Task {
            while speaker.isSpeaking || lookActive { try? await Task.sleep(nanoseconds: 200_000_000) }
            say(phrases.askMemory)
        }
    }

    func answerConsent(_ yes: Bool, heard: String) {
        awaitingConsent = false
        memory.setConsent(yes)
        if yes {
            for p in pendingPlaces { memory.add(p) }
            for f in pendingFacts { memory.remember(f.key, f.value, source: f.source) }
            for (key, fact) in facts where memory.facts[key] == nil { memory.remember(key, fact.value, source: fact.source) }
            saveRoomSoon()
        }
        pendingPlaces = []
        pendingFacts = []
        say(yes ? phrases.memoryYes : phrases.memoryNo, heard: heard)
    }

    /// Saves the room map a moment later, when ARKit has taken in the new anchor.
    func saveRoomSoon() {
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            ar.saveMap { [weak self] map in self?.memory.saveMap(map) }
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

    func forgetEverything() {
        for place in memory.places { ar.forgetPlace(place.id) }
        facts = [:]
        memory.forgetAll()
    }
}
