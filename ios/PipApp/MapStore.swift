import ARKit
import Foundation
import PipCore

/// Where Pip's map pieces live: one JSON file each (surface points, keyframes) and ARKit's own
/// map of that piece, in Documents/memory/pieces. Only written with the user's consent.
enum MapStore {
    static var dir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("memory/pieces")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func pieceURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }
    static func worldMapURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).arworldmap") }

    static func loadAll() -> [MapPiece] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(MapPiece.self, from: $0) }
        }
    }

    static func save(_ piece: MapPiece) {
        guard let data = try? JSONEncoder().encode(piece) else { return }
        try? data.write(to: pieceURL(piece.id), options: [.atomic, .completeFileProtection])
    }

    static func saveWorldMap(_ map: ARWorldMap, for id: UUID) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true) else { return }
        try? data.write(to: worldMapURL(id), options: [.atomic, .completeFileProtection])
    }

    static func loadWorldMap(_ id: UUID) -> ARWorldMap? {
        guard let data = try? Data(contentsOf: worldMapURL(id)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: pieceURL(id))
        try? FileManager.default.removeItem(at: worldMapURL(id))
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: dir)
    }
}
