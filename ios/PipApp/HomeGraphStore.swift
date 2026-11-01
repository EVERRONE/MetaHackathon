import Foundation
import PipCore

/// Where the home graph lives on this iPhone: Documents/memory/home-graph.json, only with the user's
/// memory consent, like the rest of the memory.
enum HomeGraphStore {
    static var url: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("memory/home-graph.json")
    }

    static func load() -> HomeGraph {
        guard let data = try? Data(contentsOf: url), let graph = try? JSONDecoder().decode(HomeGraph.self, from: data) else { return HomeGraph() }
        return graph
    }

    static func save(_ graph: HomeGraph) {
        guard let data = try? JSONEncoder().encode(graph) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
