import Foundation
import PipCore

/// The plans Pip made from a device's official manual, kept on this iPhone. Asked again for that
/// device and a task like it, Pip uses the plan at once, as someone who has been to your home
/// before, instead of searching the manual and drafting the plan again (4 Nov: 59 s to find the
/// washing machine's manual and 60 s for the plan, each time it was asked again).
final class PlanMemory {
    /// Plans drafted under earlier rules are not used again (4 Nov: an 11-step wash, from the tap
    /// to the detergent, where the user wanted it switched on, checked and started).
    static let rules = 4

    struct Entry: Codable {
        var rules: Int?
        var product: String
        var goal: String
        var language: String
        var procedure: Procedure
        var saved: Date
    }

    private(set) var entries: [Entry] = []
    private var url: URL { Diagnostics.documents.appendingPathComponent("plans.json") }

    init() {
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = stored
        }
    }

    /// A plan for this device and a task like this one (most words of the shorter in common).
    func plan(product: String, goal: String, language: String) -> Entry? {
        entries.last { Self.same($0, product: product, goal: goal, language: language) }
    }

    func keep(product: String, goal: String, language: String, procedure: Procedure) {
        entries.removeAll { Self.same($0, product: product, goal: goal, language: language) }
        entries.append(Entry(rules: Self.rules, product: product, goal: goal, language: language, procedure: procedure, saved: Date()))
        if entries.count > 30 { entries.removeFirst(entries.count - 30) }
        save()
    }

    func forgetAll() {
        entries = []
        try? FileManager.default.removeItem(at: url)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url)
        Diagnostics.excludeFromBackup(url)
    }

    private static func same(_ e: Entry, product: String, goal: String, language: String) -> Bool {
        e.rules == rules && e.language == language && overlap(words(e.product), words(product)) >= 0.6 && overlap(words(e.goal), words(goal)) >= 0.5
    }

    static func words(_ s: String) -> Set<String> {
        let skip: Set<String> = ["the", "a", "an", "for", "this", "my", "to", "of", "with", "on", "up", "set", "setting",
                                 "de", "het", "een", "voor", "mijn", "van", "deze", "dit", "op", "met"]
        return Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 && !skip.contains($0) })
    }

    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }
}
