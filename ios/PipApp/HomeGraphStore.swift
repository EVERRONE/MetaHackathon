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
        guard FileManager.default.fileExists(atPath: url.path) else { return HomeGraph() }
        if let data = try? Data(contentsOf: url), let graph = try? JSONDecoder().decode(HomeGraph.self, from: data) { return graph }
        // Unreadable (a damaged file, or another version's format): set aside rather than overwritten
        // by the next save, which starts the graph afresh.
        let aside = url.deletingLastPathComponent().appendingPathComponent("home-graph.unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        return HomeGraph()
    }

    static func save(_ graph: HomeGraph) {
        guard let data = try? JSONEncoder().encode(graph) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    /// The graph, and any unreadable one set aside.
    static func remove() {
        try? FileManager.default.removeItem(at: url)
        let dir = url.deletingLastPathComponent()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("home-graph.unreadable") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
