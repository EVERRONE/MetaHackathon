import Foundation
import PipCore

/// Guided tasks: the conversation proposes one, the compiler builds the plan, and the
/// deterministic runtime decides every step. Models give and check steps; they never advance.
extension GuideModel {
    var phrases: Phrases { Phrases(language: language) }

    /// Where a finished utterance goes: a hazard stops everything; during a task, short commands
    /// act at once; anything else is a question for Pip about what it sees.
    func route(_ text: String, snapshot: FrameSnapshot) {
        task?.cancel()
        if let hazard = SafetyPolicy.spokenHazard(in: text) {
            sessionLog.add(.hazard, step: runtime?.index, "user said: \(text)")
            if var rt = runtime, rt.isActive {
                let actions = rt.handle(.hazard(hazard))
                runtime = rt
                task = Task { await perform(actions, heard: text) }
            } else {
                say(SafetyPolicy.escalation(hazard, language: language), heard: text)
            }
            return
        }
        let command = Command.parse(text)
        if awaitingConsent, command == .yes || command == .no {
            answerConsent(command == .yes, heard: text)
            return
        }
        if pageReader != nil {
            let lower = text.lowercased()
            if command == .done || command == .stop || command == .skip || ["dat was het", "dat was alles", "that's all", "that was all"].contains(where: { lower.contains($0) }) {
                task = Task { await finishReading(heard: text) }
                return
            }
        }
        if offering {
            switch command {
            case .yes, .done, .resume:
                offering = false
                task = Task { await startTask(heard: text) }
                return
            case .no, .stop:
                offering = false
                endTask(silently: true)
                say(phrases.cancelled, heard: text)
                return
            default:
                break
            }
        }
        if var rt = runtime, rt.isActive, let command {
            var input: ProcedureRuntime.Input?
            switch command {
            case .yes: input = rt.expectsAnswer ? .answer(true) : .userDone
            case .no: input = rt.expectsAnswer ? .answer(false) : nil
            case .done: input = .userDone
            case .back: input = .back
            case .repeatStep: input = .repeatStep
            case .skip: input = .skip
            case .pause: input = .pause
            case .resume: input = .resume
            case .stop:
                endTask(silently: false)
                return
            }
            if let input {
                let wasGated = rt.statuses.indices.contains(rt.index) && rt.statuses[rt.index] == .gated
                let actions = rt.handle(input)
                runtime = rt
                if actions.isEmpty, wasGated, command == .no {
                    say(phrases.waitForGate, heard: text)
                } else {
                    task = Task { await perform(actions, heard: text) }
                }
                refreshTaskView()
                return
            }
        }
        let t0 = Date()
        task = Task { await look(text, snapshot: snapshot, started: t0) }
    }

    /// Carries out the runtime's actions in order.
    func perform(_ actions: [ProcedureRuntime.Action], heard: String? = nil) async {
        var first = true
        for action in actions {
            if Task.isCancelled { return }
            let userWords = first ? heard : nil
            first = false
            switch action {
            case .instruct(let i):
                await instruct(i)
            case .verify(let i):
                await verify(i)
            case .askGate(_, let condition):
                say(phrases.gate(condition), heard: userWords)
            case .askResult(_, let expected):
                say(phrases.askResult(expected), heard: userWords)
            case .cannotCheck(let i, let expected):
                sessionLog.add(.notVerifiable, step: i, expected)
                say(phrases.cannotCheck(expected), heard: userWords)
            case .stepDone(let i, let outcome):
                switch outcome {
                case .cameraVerified:
                    sessionLog.add(.verified, step: i, "seen on camera")
                    ar.markVerified()
                    say(phrases.verified, heard: userWords)
                case .userConfirmed:
                    sessionLog.add(.confirmed, step: i, "confirmed by the user")
                    say(phrases.confirmed, heard: userWords)
                case .notVerifiable:
                    break
                case .skipped:
                    sessionLog.add(.skipped, step: i, "skipped")
                }
            case .finished:
                sessionLog.add(.finished, "all steps done")
                say(phrases.finished, heard: userWords)
            case .stopped(let reason):
                sessionLog.add(.stopped, step: runtime?.index, reason)
                say(SafetyPolicy.escalation(reason, language: language), heard: userWords)
            case .paused:
                say(phrases.paused, heard: userWords)
            case .resumed:
                say(phrases.resumed, heard: userWords)
            }
            refreshTaskView()
        }
    }

    private func instruct(_ i: Int) async {
        guard let rt = runtime, rt.procedure.steps.indices.contains(i), let snapshot = ar.snapshot() else { return }
        let step = rt.procedure.steps[i]
        let targets = step.targets.compactMap { rt.procedure.object($0) }
            .map { $0.text.isEmpty ? $0.name : "\($0.name) (printed: \($0.text.joined(separator: ", ")))" }
            .joined(separator: " and ")
        let text = ProcedureStepText(instruction: step.instruction, why: step.why, targets: targets,
                                     cautions: (step.cautions + (i == 0 ? rt.procedure.cautions : [])).joined(separator: "; "))
        sessionLog.add(.instructed, step: i, step.instruction)
        await look("(step \(i + 1))", snapshot: snapshot, started: Date(), directive: phrases.instruct(step: i + 1, of: rt.procedure.steps.count, text))
        if var current = runtime, current.index == i {
            _ = current.handle(.instructed)
            runtime = current
        }
        refreshTaskView()
    }

    private func verify(_ i: Int) async {
        guard let rt = runtime, rt.procedure.steps.indices.contains(i), let snapshot = ar.snapshot() else { return }
        let expected = rt.procedure.steps[i].check.expected
        var evidence: (seen: Bool, confidence: Double)?
        await look("(check step \(i + 1))", snapshot: snapshot, started: Date(), directive: phrases.verify(step: i + 1, expected: expected)) { state in
            evidence = (state["step"] == "done", Double(state["conf"] ?? "") ?? 0)
        }
        guard var current = runtime, current.index == i, !Task.isCancelled else { return }
        let actions = current.handle(.verified(seen: evidence?.seen ?? false, confidence: evidence?.confidence ?? 0))
        runtime = current
        await perform(actions)
    }

    // MARK: Preparing and ending

    func startReading(goal: String) {
        let reader = PageReader()
        reader.onPage = { [weak self] n in
            guard let self else { return }
            self.speaker.enqueue(SpokenSentence(text: self.phrases.page(n)))
            self.preparing = self.phrases.readingStatus(n)
        }
        pageReader = reader
        readingGoal = goal
        preparing = phrases.readingStatus(0)
    }

    func finishReading(heard: String) async {
        let pages = pageReader?.pages ?? []
        pageReader = nil
        preparing = nil
        guard !pages.isEmpty else {
            say(phrases.noPages, heard: heard)
            return
        }
        say(phrases.readPages(pages.count), heard: heard)
        facts["instructions"] = Fact(value: "\(pages.count) pages shown for: \(readingGoal)", source: "seen")
        await prepareTask(goal: readingGoal.isEmpty ? "the task in these instructions" : readingGoal, product: nil, source: .images(pages))
    }

    func prepareTask(goal: String, product: String?, source given: ProcedureCompiler.SourceInput? = nil) async {
        if case .refused(let reason) = SafetyPolicy.classify(goal) {
            say(SafetyPolicy.refusal(reason, language: language))
            return
        }
        let compiler = ProcedureCompiler(client: client, language: language)
        var source = given ?? .none
        if given != nil {
            preparing = phrases.drafting
        } else if let product {
            preparing = phrases.searching(product)
            say(phrases.searching(product))
            if let manual = try? await compiler.findManual(for: product) {
                source = .manual(manual)
                preparing = phrases.reading(manual.publisher)
                say(phrases.reading(manual.publisher))
            } else {
                preparing = phrases.noManual
                say(phrases.noManual)
            }
        } else {
            preparing = phrases.drafting
            say(phrases.drafting)
        }
        if Task.isCancelled { preparing = nil; return }
        let frame = ar.snapshot().flatMap { SetOfMarks.jpeg($0.image, quality: 0.8) }
        let known = facts.map { "\($0.key): \($0.value.value)" }
        do {
            let compiled = try await compiler.compile(goal: goal, source: source, frameJPEG: frame, facts: known)
            preparing = nil
            if case .refused(let reason) = compiled.classification {
                say(SafetyPolicy.refusal(reason, language: language))
                return
            }
            runtime = ProcedureRuntime(procedure: compiled.procedure)
            sessionLog = SessionLog()
            sessionLog.add(.started, "\(compiled.procedure.title) · source: \(compiled.procedure.source.reference ?? "none")")
            refreshTaskView()
            if let note = compiled.mismatch { say(phrases.mismatch(note)) }
            offering = true
            say(phrases.offer(compiled.procedure.steps.count, verified: compiled.procedure.source.verified))
        } catch {
            preparing = nil
            log("compile failed: \(error)")
            say(phrases.prepareFailed)
        }
    }

    func startTask(heard: String) async {
        guard var rt = runtime else { return }
        let actions = rt.handle(.start)
        runtime = rt
        await perform(actions, heard: heard)
    }

    func endTask(silently: Bool) {
        let wasActive = runtime?.isActive == true
        if wasActive { sessionLog.add(.stopped, step: runtime?.index, "stopped by the user") }
        if let rt = runtime, wasActive || rt.mode == .finished {
            taskView?.report = sessionLog.report(for: rt.procedure, runtime: rt)
            taskView?.finished = true
        }
        if !wasActive { taskView = nil }
        runtime = nil
        offering = false
        preparing = nil
        if !silently && wasActive { say(phrases.stopped) }
    }

    /// Speaks a fixed sentence and keeps it in the conversation history.
    func say(_ text: String, heard: String? = nil) {
        speaker.enqueue(SpokenSentence(text: text))
        phase = .speaking
        history.append(.user(heard ?? "(Pip continues)"))
        history.append(.assistant(text))
        if history.count > 16 { history.removeFirst(history.count - 16) }
    }

    func refreshTaskView() {
        guard let rt = runtime else { return }
        let steps = rt.procedure.steps.enumerated().map { i, s -> StepView in
            let state: String
            switch rt.statuses[i] {
            case .done(.cameraVerified): state = "checkmark.circle.fill"
            case .done(.userConfirmed): state = "person.fill.checkmark"
            case .done(.notVerifiable): state = "checkmark.circle"
            case .done(.skipped): state = "arrow.uturn.forward"
            case .gated: state = "exclamationmark.shield"
            case .awaitingAction, .verifying: state = "hand.point.right.fill"
            case .pending: state = "circle"
            }
            return StepView(id: i, text: s.instruction, state: state, sourceRef: s.sourceRef)
        }
        let finished = rt.mode == .finished
        taskView = TaskView(title: rt.procedure.title,
                            source: rt.procedure.source.verified ? (rt.procedure.source.reference ?? "") : (language == "Dutch" ? "Geen gecontroleerde bron" : "Not from a verified source"),
                            steps: steps, index: rt.index, finished: finished,
                            report: finished ? sessionLog.report(for: rt.procedure, runtime: rt) : taskView?.report)
    }
}
