import Foundation

/// The deterministic step engine. The models perceive and explain; only this decides progress.
/// A step is done when the camera shows its result, the user confirms what cannot be seen, or it
/// cannot be checked at all (and Pip says so). The model can never skip a step.
public struct ProcedureRuntime: Sendable {
    public enum Outcome: String, Codable, Equatable, Sendable {
        case cameraVerified, userConfirmed, notVerifiable, skipped
    }

    public enum Status: Equatable, Sendable {
        case pending
        /// Waiting for the user to confirm the step's safety condition.
        case gated
        /// Instruction given; waiting for the user to act.
        case awaitingAction
        /// Pip is checking the result (a camera look, or a question to the user).
        case verifying
        case done(Outcome)
    }

    public enum Mode: Equatable, Sendable {
        case running, paused, finished
        case stopped(reason: String)
    }

    public enum Input: Equatable, Sendable {
        case start
        /// The step's instruction has been spoken.
        case instructed
        /// The user says they did it ("klaar", "done", "next").
        case userDone
        /// A verification look: whether the expected result is visible, and how sure.
        case verified(seen: Bool, confidence: Double)
        /// The answer to a yes/no question: the step's result, or its safety condition.
        case answer(Bool)
        case back, repeatStep, skip, pause, resume
        case hazard(String)
    }

    /// What the conversation layer must do next.
    public enum Action: Equatable, Sendable {
        /// Ask the user to confirm a safety condition before the step starts.
        case askGate(step: Int, condition: String)
        /// Speak the step and point at its targets (a look with the step as context).
        case instruct(step: Int)
        /// Look again and check the step's expected result.
        case verify(step: Int)
        /// Ask the user whether the expected result is there.
        case askResult(step: Int, expected: String)
        /// The step cannot be checked here; Pip says so and moves on.
        case cannotCheck(step: Int, expected: String)
        case stepDone(step: Int, outcome: Outcome)
        case finished
        case stopped(reason: String)
        case paused, resumed
    }

    /// Below this, a verification look does not count as camera evidence.
    public static let minConfidence = 0.7
    /// After this many looks without the result, Pip asks the user instead of looking again.
    public static let lookAttempts = 2

    public private(set) var procedure: Procedure
    public private(set) var statuses: [Status]
    public private(set) var index = 0
    public private(set) var mode: Mode = .paused
    private var gatesConfirmed = Set<Int>()
    private var failedLooks = 0
    /// What the last yes/no question was about.
    private var pendingQuestion: Question?

    private enum Question: Equatable, Sendable { case gate, result }

    public init(procedure: Procedure) {
        self.procedure = procedure
        statuses = Array(repeating: .pending, count: procedure.steps.count)
    }

    public var current: Procedure.Step? { procedure.steps.indices.contains(index) ? procedure.steps[index] : nil }
    public var isActive: Bool { mode == .running || mode == .paused }
    public var doneCount: Int { statuses.filter { if case .done = $0 { return true } else { return false } }.count }
    public var expectsAnswer: Bool { pendingQuestion != nil }

    public mutating func handle(_ input: Input) -> [Action] {
        if case .stopped = mode { return [] }
        if mode == .finished { return [] }
        switch input {
        case .hazard(let reason):
            mode = .stopped(reason: reason)
            pendingQuestion = nil
            return [.stopped(reason: reason)]
        case .start:
            mode = .running
            return enter(0)
        case .pause:
            guard mode == .running else { return [] }
            mode = .paused
            return [.paused]
        case .resume:
            guard mode == .paused else { return [] }
            mode = .running
            return [.resumed] + enter(index)
        default:
            break
        }
        guard mode == .running, current != nil else { return [] }

        switch input {
        case .instructed:
            if statuses[index] != .gated { statuses[index] = .awaitingAction }
            return []
        case .userDone:
            guard statuses[index] == .awaitingAction || statuses[index] == .verifying else { return [] }
            return check()
        case .verified(let seen, let confidence):
            guard statuses[index] == .verifying else { return [] }
            if seen && confidence >= Self.minConfidence { return complete(.cameraVerified) }
            failedLooks += 1
            if failedLooks >= Self.lookAttempts {
                pendingQuestion = .result
                return [.askResult(step: index, expected: current!.check.expected)]
            }
            statuses[index] = .awaitingAction
            return []
        case .answer(let yes):
            let question = pendingQuestion
            pendingQuestion = nil
            switch question {
            case .gate:
                guard yes else { return [] } // wait until the condition holds; the user says so
                gatesConfirmed.insert(index)
                statuses[index] = .pending
                return enter(index)
            case .result:
                if yes { return complete(.userConfirmed) }
                statuses[index] = .awaitingAction
                failedLooks = 0
                return [.instruct(step: index)]
            case nil:
                return []
            }
        case .back:
            guard index > 0 else { return [.instruct(step: index)] }
            statuses[index] = .pending
            index -= 1
            statuses[index] = .pending
            return enter(index)
        case .repeatStep:
            return [.instruct(step: index)]
        case .skip:
            return complete(.skipped)
        default:
            return []
        }
    }

    private mutating func enter(_ i: Int) -> [Action] {
        index = i
        failedLooks = 0
        pendingQuestion = nil
        guard let step = current else {
            mode = .finished
            return [.finished]
        }
        if let gate = step.gate, !gatesConfirmed.contains(i) {
            statuses[i] = .gated
            pendingQuestion = .gate
            return [.askGate(step: i, condition: gate)]
        }
        statuses[i] = .awaitingAction
        return [.instruct(step: i)]
    }

    private mutating func check() -> [Action] {
        let step = current!
        switch step.check.kind {
        case .camera:
            statuses[index] = .verifying
            return [.verify(step: index)]
        case .user:
            statuses[index] = .verifying
            pendingQuestion = .result
            return [.askResult(step: index, expected: step.check.expected)]
        case .none:
            return [.cannotCheck(step: index, expected: step.check.expected)] + complete(.notVerifiable)
        }
    }

    private mutating func complete(_ outcome: Outcome) -> [Action] {
        statuses[index] = .done(outcome)
        let done = index
        return [.stepDone(step: done, outcome: outcome)] + enter(index + 1)
    }
}
