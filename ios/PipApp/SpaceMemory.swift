import ARKit
import Foundation
import PipCore
import simd

/// What Pip remembers across sessions, only after the user agreed, and only on this iPhone:
/// the places in the home and facts about the user's devices. The 3D map itself is kept as map
/// pieces (MapStore, MapKeeper).
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
        /// The map piece the place belongs to, and its anchor's pose in that piece (column-major),
        /// so it can be brought back when the piece is linked into a later session.
        var piece: UUID?
        var pose: [Float]?
        /// What it is to the detector and what is printed on it, to find it again on sight and
        /// correct its position to the centimetre.
        var phrase: String?
        var text: [String]?
        /// What the model said it is ("the grey pen in the middle"): finding it again among
        /// look-alikes (three pens side by side) is done by it.
        var description: String? = nil
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

    nonisolated static let consentKey = "pip.memoryConsent"
    private let dir: URL
    /// False when memory.json is there but cannot be read now (the phone is locked): this session
    /// leaves it alone rather than overwrite it with less.
    private var writable = true
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
        if let v = UserDefaults.standard.object(forKey: Self.consentKey) as? Bool { consent = v }
        guard consent == true, FileManager.default.fileExists(atPath: dataURL.path) else { return }
        guard let data = try? Data(contentsOf: dataURL) else {
            writable = false
            return
        }
        if let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            places = stored.places
            facts = stored.facts
        } else {
            // Not what Pip writes (written before saves were atomic, or by another version): kept
            // aside, never overwritten.
            try? FileManager.default.moveItem(at: dataURL, to: dir.appendingPathComponent("memory.unreadable-\(Int(Date().timeIntervalSince1970)).json"))
        }
    }

    func setConsent(_ yes: Bool) {
        consent = yes
        UserDefaults.standard.set(yes, forKey: Self.consentKey)
        if !yes { forgetAll() }
    }

    func add(_ place: Place) {
        guard consent == true else { return }
        places.removeAll { $0.name.lowercased() == place.name.lowercased() }
        places.append(place)
        save()
    }

    /// Replaces stored places (after they moved into another map piece).
    func update(_ changed: [Place]) {
        guard consent == true, !changed.isEmpty else { return }
        for p in changed {
            if let i = places.firstIndex(where: { $0.id == p.id }) { places[i] = p } else { places.append(p) }
        }
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
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("memory.unreadable") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        MapStore.removeAll()
        VisualMemoryStore.removeAll()
    }

    /// The map from before map pieces (one room): it becomes a piece of its own, with its places.
    func migrateLegacyMap() {
        guard consent == true, FileManager.default.fileExists(atPath: mapURL.path) else { return }
        let piece = MapPiece()
        MapStore.save(piece)
        try? FileManager.default.moveItem(at: mapURL, to: MapStore.worldMapURL(piece.id))
        for i in places.indices where places[i].piece == nil { places[i].piece = piece.id }
        save()
    }

    private func save() {
        guard consent == true, writable, let data = try? JSONEncoder().encode(Stored(places: places, facts: facts)) else { return }
        try? data.write(to: dataURL, options: [.atomic, .completeFileProtection])
    }
}
