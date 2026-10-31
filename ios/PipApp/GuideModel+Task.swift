import Foundation
import PipCore

/// Guided tasks: the conversation proposes one, the compiler builds the plan, and the
/// deterministic runtime decides every step. Models give and check steps; they never advance.
extension GuideModel {
    var phrases: Phrases { Phrases(language: language) }

    /// Where a finished utterance goes. In order: a hazard stops everything; an open question
    /// (memory consent, the task offer, a safety gate) takes its answer; short commands act at
    /// once during a task; a plain "okay" or "thanks" needs no look; anything else is a question
    /// for Pip about what it sees.
    func route(_ text: String, snapshot: FrameSnapshot) {
        // Pip answers in the language the user speaks.
        if let spoken = Utterance.language(of: text), spoken != language {
            log("language: \(spoken)")
            adoptLanguage(spoken)
        }
        if let hazard = SafetyPolicy.spokenHazard(in: text) {
            sessionLog.add(.hazard, step: runtime?.index, "user said: \(text)")
            task?.cancel()
            prepTask?.cancel()
            if var rt = runtime, rt.isActive {
                let actions = rt.handle(.hazard(hazard))
                runtime = rt
                task = Task { await perform(actions, heard: text) }
            } else {
                offering = false
                say(SafetyPolicy.escalation(hazard, language: language), heard: text)
            }
            return
        }
        let command = Command.parse(text)
        let ack = Utterance.acknowledgement(text)
        // "ja" or "yes, I'm in Settings now". A bare "okay" accepts an offer, but never answers
        // a safety question.
        let explicitYes = command == .yes || (command == nil && ack == nil && Utterance.startsWithYes(text))
        let yes = explicitYes || ack == .okay
        let no = command == .no

        if awaitingConsent {
            if yes || no {
                answerConsent(yes, heard: text)
                return
            }
            // The user moved on: Pip asks again another time.
            awaitingConsent = false
        }
        if pageReader != nil, handleWhileReading(text, command: command) { return }
        if prepTask != nil, command == .stop {
            prepTask?.cancel()
            prepTask = nil
            preparingGoal = nil
            preparing = nil
            say(phrases.cancelled, heard: text)
            return
        }
        if offering {
            if yes || command == .done || command == .resume {
                offering = false
                task?.cancel()
                task = Task { await startTask(heard: text) }
                return
            }
            if no || command == .stop {
                offering = false
                endTask(silently: true)
                say(phrases.cancelled, heard: text)
                return
            }
        }
        if let rt = runtime, rt.isActive, handleDuringTask(text, command: command, yes: explicitYes, no: no, ack: ack) { return }
        if let ack {
            // Nothing to look at: "okay" gets silence, "thanks" a short reply.
            if ack == .thanks { say(phrases.welcome, heard: text) } else { phase = muted ? .muted : .listening }
            return
        }
        task?.cancel()
        let t0 = Date()
        task = Task { await look(text, snapshot: snapshot, started: t0) }
    }

    /// Commands and answers during a running task. Returns false when the utterance is a question
    /// for the model instead.
    private func handleDuringTask(_ text: String, command: Command?, yes: Bool, no: Bool, ack: Utterance.Acknowledgement?) -> Bool {
        guard var rt = runtime else { return false }
        if command == .stop {
            endTask(silently: false)
            return true
        }
        if rt.expectsAnswer, yes || no {
            guard let question = rt.pendingQuestionAction else { return false }
            // Other talk came in between: ask the open question again instead of guessing what
            // this yes or no is about. A safety gate is never confirmed by a stray "yes".
            guard questionFresh else {
                task?.cancel()
                task = Task { await perform([question], heard: text) }
                return true
            }
            let wasGated = rt.statuses.indices.contains(rt.index) && rt.statuses[rt.index] == .gated
            let actions = rt.handle(.answer(yes))
            runtime = rt
            if actions.isEmpty, wasGated, no {
                say(phrases.waitForGate, heard: text)
            } else {
                questionFresh = false
                task?.cancel()
                task = Task { await perform(actions, heard: text) }
            }
            refreshTaskView()
            return true
        }
        var input: ProcedureRuntime.Input?
        switch command {
        case .yes?, .done?: input = .userDone
        case .back?: input = .back
        case .repeatStep?: input = .repeatStep
        case .skip?: input = .skip
        case .pause?: input = .pause
        // "ga verder" while running means the next step; while paused it resumes.
        case .resume?: input = rt.mode == .paused ? .resume : .userDone
        case .no?, .stop?, nil: input = nil
        }
        guard let input else {
            // "okay" while Pip waits for the step: nothing to do.
            if ack != nil {
                phase = muted ? .muted : .listening
                return true
            }
            return false
        }
        let actions = rt.handle(input)
        runtime = rt
        if actions.isEmpty {
            // Nothing changes (a check is already running, or the task is paused): say where things stand.
            if rt.mode == .paused { say(phrases.paused, heard: text) } else { phase = muted ? .muted : .listening }
        } else {
            task?.cancel()
            task = Task { await perform(actions, heard: text) }
        }
        refreshTaskView()
        return true
    }

    /// While the user shows paper pages: "klaar" finishes, "stop" cancels, "next page" is ignored.
    private func handleWhileReading(_ text: String, command: Command?) -> Bool {
        let words = Set(Utterance.words(text))
        let lower = text.lowercased()
        if command == .stop || command == .pause || words.contains("annuleer") || words.contains("cancel") {
            cancelReading()
            say(phrases.cancelled, heard: text)
            return true
        }
        let finished = !words.isDisjoint(with: ["klaar", "gedaan", "done", "finished"])
            || ["dat was het", "dat was alles", "that's all", "that was all", "that's it"].contains { lower.contains($0) }
        if finished, command != .no {
            let pages = pageReader?.pages ?? []
            let goal = readingGoal.isEmpty ? "the task in these instructions" : readingGoal
            cancelReading()
            startPreparing(goal: goal, product: nil, pages: pages, heard: text)
            return true
        }
        // "volgende", "next page", "skip": the reader takes pages by itself.
        return command == .done || command == .skip || command == .resume || command == .no
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
                questionFresh = true
            case .askResult(_, let expected):
                say(phrases.askResult(expected), heard: userWords)
                questionFresh = true
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
                // The task is over: the card shows the report, and a new task can be started.
                if let rt = runtime {
                    taskView?.report = sessionLog.report(for: rt)
                    taskView?.finished = true
                }
                runtime = nil
                offering = false
                questionFresh = false
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
        var alreadyDone = false
        await look("(step \(i + 1))", snapshot: snapshot, started: Date(), directive: phrases.instruct(step: i + 1, of: rt.procedure.steps.count, text)) { state in
            alreadyDone = state["step"] == "done" && (Double(state["conf"] ?? "") ?? 0) >= 0.8
        }
        if var current = runtime, current.index == i {
            _ = current.handle(.instructed)
            runtime = current
        }
        // Watching starts afresh for this step. When the step's result was already visible, that
        // counts as the first of the two sightings watching needs, so Pip moves on after one more.
        watchStep = i
        watchChecks = 0
        problemHits = 0
        watchHits = alreadyDone && step.check.kind == .camera ? 1 : 0
        if alreadyDone { log("step \(i + 1) looks done already") }
        refreshTaskView()
    }

    private func verify(_ i: Int) async {
        guard let rt = runtime, rt.procedure.steps.indices.contains(i), let snapshot = ar.snapshot() else {
            _ = runtime?.handle(.interrupted)
            return
        }
        let expected = rt.procedure.steps[i].check.expected
        var evidence: (seen: Bool, confidence: Double)?
        await look("(check step \(i + 1))", snapshot: snapshot, started: Date(), directive: phrases.verify(step: i + 1, expected: expected)) { state in
            evidence = (state["step"] == "done", Double(state["conf"] ?? "") ?? 0)
        }
        guard var current = runtime, current.index == i else { return }
        guard !Task.isCancelled else {
            // Cut off: the step waits for the user again, and watching resumes.
            _ = current.handle(.interrupted)
            runtime = current
            return
        }
        let actions = current.handle(.verified(seen: evidence?.seen ?? false, confidence: evidence?.confidence ?? 0))
        runtime = current
        await perform(actions)
    }

    // MARK: Preparing and ending

    func startReading(goal: String) {
        // Already reading: keep the pages taken so far.
        guard pageReader == nil else { return }
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

    func cancelReading() {
        pageReader = nil
        preparing = nil
    }

    /// Prepares a plan in the background: the conversation goes on while Pip searches and reads
    /// (about a minute), and Pip offers the plan when it is ready. Only "stop" cancels it.
    func startPreparing(goal: String, product: String?, pages: [Data]? = nil, heard: String? = nil) {
        prepTask?.cancel()
        preparingGoal = goal
        prepTask = Task {
            if let pages {
                if pages.isEmpty {
                    say(phrases.noPages, heard: heard)
                } else {
                    say(phrases.readPages(pages.count), heard: heard)
                    facts["instructions"] = Fact(value: "\(pages.count) pages shown for: \(goal)", source: "seen")
                    await prepareTask(goal: goal, product: nil, source: .images(pages))
                }
            } else {
                await prepareTask(goal: goal, product: product)
            }
            if !Task.isCancelled {
                prepTask = nil
                preparingGoal = nil
            }
        }
    }

    private func prepareTask(goal: String, product: String?, source given: ProcedureCompiler.SourceInput? = nil) async {
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
            let manual = try? await compiler.findManual(for: product)
            if Task.isCancelled { preparing = nil; return }
            if let manual {
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
        let frame = ar.snapshot().flatMap { SetOfMarks.jpeg($0.image, quality: 0.8) }
        let known = facts.map { "\($0.key): \($0.value.value)" }
        var compiled: ProcedureCompiler.Compiled?
        do {
            compiled = try await compiler.compile(goal: goal, source: source, frameJPEG: frame, facts: known)
        } catch {
            log("compile failed: \(error)")
            // A manual that cannot be read: a plan from general knowledge, clearly marked as such.
            if case .manual = source, !Task.isCancelled {
                say(phrases.manualUnreadable)
                compiled = try? await compiler.compile(goal: goal, source: .none, frameJPEG: frame, facts: known)
            }
        }
        preparing = nil
        if Task.isCancelled { return }
        guard let compiled else {
            say(phrases.prepareFailed)
            return
        }
        if case .refused(let reason) = compiled.classification {
            say(SafetyPolicy.refusal(reason, language: language))
            return
        }
        // A task that started meanwhile is not replaced.
        if runtime?.isActive == true { return }
        runtime = ProcedureRuntime(procedure: compiled.procedure)
        sessionLog = SessionLog()
        sessionLog.add(.started, "\(compiled.procedure.title) · source: \(compiled.procedure.source.reference ?? "none")")
        refreshTaskView()
        if let note = compiled.mismatch { say(phrases.mismatch(note)) }
        offering = true
        say(phrases.offer(compiled.procedure.steps.count, verified: compiled.procedure.source.verified))
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
            taskView?.report = sessionLog.report(for: rt)
            taskView?.finished = true
        } else if runtime != nil {
            // Only offered, never started: nothing to report.
            taskView = nil
        }
        runtime = nil
        offering = false
        questionFresh = false
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
                            report: finished ? sessionLog.report(for: rt) : taskView?.report)
    }
}
