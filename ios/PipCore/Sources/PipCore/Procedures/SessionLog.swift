import Foundation

/// Append-only record of a task session. Summaries and the hand-over report come only from here,
/// never from the model's memory of the conversation.
public struct SessionLog: Codable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case started, said, heard, instructed, verified, confirmed, notVerifiable, skipped, hazard, stopped, finished, fact
        }
        public var time: Date
        public var kind: Kind
        public var step: Int?
        public var text: String
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public mutating func add(_ kind: Entry.Kind, step: Int? = nil, _ text: String, at time: Date = Date()) {
        entries.append(Entry(time: time, kind: kind, step: step, text: text))
    }

    /// A plain-text report for a professional: what was done and how each step was checked.
    public func report(for runtime: ProcedureRuntime) -> String {
        let procedure = runtime.procedure
        var lines = ["Task: \(procedure.title)", "Goal: \(procedure.goal)",
                     "Source: " + (procedure.source.verified ? (procedure.source.reference ?? procedure.source.kind.rawValue) : "none (drafted by Pip, not from a verified source)"), ""]
        for (i, step) in procedure.steps.enumerated() {
            let status: String
            switch runtime.statuses[i] {
            case .done(.cameraVerified): status = "done, seen on camera"
            case .done(.userConfirmed): status = "done, confirmed by the user"
            case .done(.notVerifiable): status = "done, could not be checked"
            case .done(.skipped): status = "skipped"
            default: status = "not done"
            }
            lines.append("\(i + 1). \(step.instruction) [\(status)]")
        }
        let hazards = entries.filter { $0.kind == .hazard || $0.kind == .stopped }
        if !hazards.isEmpty {
            lines.append("")
            lines += hazards.map { ($0.kind == .hazard ? "Hazard: " : "Stopped: ") + $0.text }
        }
        return lines.joined(separator: "\n")
    }
}
