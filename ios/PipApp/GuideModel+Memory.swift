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

    func saveRoomNow() {
        guard memory.consent == true, !memory.places.isEmpty else { return }
        let memory = memory
        ar.saveMap { map in memory.saveMap(map) }
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
        facts = [:]
        pendingPlaces = []
        pendingFacts = []
        memory.forgetAll()
    }
}
