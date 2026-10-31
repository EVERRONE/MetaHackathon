import ARKit
import Foundation
import simd

/// What Pip remembers across sessions, only after the user agreed, and only on this iPhone:
/// the map of the room (so ARKit recognises it again), the places in it, and facts about the
/// user's devices.
@MainActor
final class SpaceMemory: ObservableObject {
    struct Place: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        /// The ARKit anchor that holds this place in the saved room map.
        var anchorID: UUID
        /// The outline relative to the anchor, in metres.
        var outline: [[SIMD3<Float>]]
        var created: Date
    }

    struct Fact: Codable, Equatable {
        var value: String
        var source: String
        var date: Date
    }

    @Published private(set) var places: [Place] = []
    @Published private(set) var facts: [String: Fact] = [:]
    /// nil until the user has been asked; then their answer.
    @Published private(set) var consent: Bool?

    private let dir: URL
    private var mapURL: URL { dir.appendingPathComponent("room.arworldmap") }
    private var dataURL: URL { dir.appendingPathComponent("memory.json") }

    private struct Stored: Codable {
        var places: [Place]
        var facts: [String: Fact]
    }

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("memory")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let v = UserDefaults.standard.object(forKey: "pip.memoryConsent") as? Bool { consent = v }
        if consent == true, let data = try? Data(contentsOf: dataURL), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            places = stored.places
            facts = stored.facts
        }
    }

    func setConsent(_ yes: Bool) {
        consent = yes
        UserDefaults.standard.set(yes, forKey: "pip.memoryConsent")
        if !yes { forgetAll() }
    }

    func add(_ place: Place) {
        guard consent == true else { return }
        places.removeAll { $0.name.lowercased() == place.name.lowercased() }
        places.append(place)
        save()
    }

    func remove(_ id: UUID) {
        places.removeAll { $0.id == id }
        save()
    }

    func remember(_ key: String, _ value: String, source: String) {
        guard consent == true else { return }
        facts[key] = Fact(value: value, source: source, date: Date())
        save()
    }

    func forget(fact key: String) {
        facts[key] = nil
        save()
    }

    func forgetAll() {
        places = []
        facts = [:]
        try? FileManager.default.removeItem(at: dataURL)
        try? FileManager.default.removeItem(at: mapURL)
    }

    private func save() {
        guard consent == true, let data = try? JSONEncoder().encode(Stored(places: places, facts: facts)) else { return }
        try? data.write(to: dataURL, options: .completeFileProtection)
    }

    func saveMap(_ map: ARWorldMap) {
        guard consent == true, let data = try? NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true) else { return }
        try? data.write(to: mapURL, options: .completeFileProtection)
    }

    func loadMap() -> ARWorldMap? {
        guard consent == true, let data = try? Data(contentsOf: mapURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }
}
