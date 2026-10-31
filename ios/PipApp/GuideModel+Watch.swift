import Foundation
import PipCore

/// Pip notices on its own when a step is done, follows objects that move, snaps outlines back
/// when the user returns, and keeps to the person it is talking with.
extension GuideModel {
    static let watchInterval: TimeInterval = 3
    static let refreshInterval: TimeInterval = 2
    /// Positive checks in a row before a step counts as seen done.
    static let watchHitsNeeded = 2
    /// At most this many checks per step (about three minutes), to bound cost.
    static let watchChecksPerStep = 60

    func startWatching() {
        watchTimer = Timer.scheduledTimer(withTimeInterval: Self.watchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.watchTick() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshTick() }
        }
    }

    // MARK: Speakers

    /// Keeps to the person Pip talks with. The first speaker in a session becomes that person;
    /// someone else is heard only when they address Pip by name.
    func acceptSpeaker(_ speaker: String?, text: String) -> Bool {
        guard let speaker else { return true }
        guard let primary = primarySpeaker else {
            primarySpeaker = speaker
            return true
        }
        if speaker == primary { return true }
        if text.lowercased().contains("pip") {
            log("speaker \(speaker) addressed Pip")
            return true
        }
        log("ignored speaker \(speaker): \(text)")
        heard = "(\(language == "Dutch" ? "iemand anders" : "someone else")) \(text)"
        if phase == .hearing { phase = muted ? .muted : .listening }
        return false
    }

    // MARK: Watching mode

    /// While a camera-checked step waits for the user, look every few seconds whether its result
    /// is visible. Two positive checks in a row count as camera evidence; the runtime decides.
    private func watchTick() async {
        guard var rt = runtime, rt.mode == .running, let step = rt.current,
              rt.statuses.indices.contains(rt.index), rt.statuses[rt.index] == .awaitingAction,
              step.check.kind == .camera else {
            watching = false
            return
        }
        if watchStep != rt.index {
            watchStep = rt.index
            watchHits = 0
            watchChecks = 0
            problemHits = 0
        }
        guard !checking, !lookActive, !speaker.isSpeaking, phase != .hearing, !muted, ar.trackingNormal,
              watchChecks < Self.watchChecksPerStep, let snapshot = ar.snapshot() else { return }
        checking = true
        watching = true
        watchChecks += 1
        defer { checking = false }
        let boxes = ar.visibleMarkBoxes(in: snapshot).map(\.box)
        let focus = boxes.isEmpty ? nil : boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
        let index = rt.index
        let next = rt.procedure.steps.indices.contains(index + 1) ? rt.procedure.steps[index + 1].instruction : nil
        let context = StepChecker.StepContext(instruction: step.instruction, expected: step.check.expected,
                                              cautions: step.cautions + rt.procedure.cautions, nextInstruction: next)
        guard let result = try? await StepChecker(client: client).check(snapshot.image, step: context, focus: focus) else { return }
        log(String(format: "watch step %d: %@ %.2f %@ · problem %@ %.2f %@", index + 1, result.done ? "done" : "not yet", result.confidence, result.seen,
                   result.problem.rawValue, result.problemConfidence, result.problemText))
        guard let now = runtime, now.index == index, now.statuses[index] == .awaitingAction, !lookActive, !speaker.isSpeaking else { return }

        // A mistake seen twice in a row is checked by Wonder, which corrects the user and points at
        // the right object, or stays silent when it was a false alarm.
        if result.problem != .none, result.problemConfidence >= 0.75, !result.done {
            problemHits = result.problem == lastProblem ? problemHits + 1 : 1
            lastProblem = result.problem
        } else {
            problemHits = 0
            lastProblem = .none
        }
        if problemHits >= 2 {
            problemHits = 0
            let problem = result
            task?.cancel()
            task = Task { await correct(problem, step: index) }
            return
        }
        if result.done && result.confidence >= ProcedureRuntime.minConfidence {
            watchHits += 1
        } else {
            watchHits = 0
        }
        guard watchHits >= Self.watchHitsNeeded else { return }
        watchHits = 0
        rt = now
        _ = rt.handle(.userDone)
        let actions = rt.handle(.verified(seen: true, confidence: result.confidence))
        runtime = rt
        sessionLog.add(.verified, step: index, "seen while watching: \(result.seen)")
        task?.cancel()
        task = Task { await perform(actions) }
    }

    /// Wonder looks at the suspected mistake: it interrupts with a correction and points at the right
    /// object, or says nothing. A confirmed hazard stops the task.
    private func correct(_ problem: StepChecker.Result, step index: Int) async {
        guard let snapshot = ar.snapshot() else { return }
        let directive = """
        While watching the current step, a quick check thought something is going wrong: "\(problem.problemText)" (\(problem.problem.rawValue)). \
        Look carefully at the image. If it is really happening, interrupt the user at once in one or two short sentences: \
        say what is wrong and what to do instead, and point at the right object\(problem.problem == .hazard ? ", or flag the danger" : ""). \
        If it is not happening, say nothing at all: give only the state tag.
        """
        sessionLog.add(.said, step: index, "possible mistake: \(problem.problemText)")
        await look("(watching step \(index + 1))", snapshot: snapshot, started: Date(), directive: directive)
        let spoke = !spokenThisTurn.isEmpty
        log(spoke ? "corrected: \(problem.problemText)" : "false alarm: \(problem.problemText)")
        if spoke, problem.problem == .hazard, var rt = runtime, rt.isActive {
            let actions = rt.handle(.hazard(problem.problemText))
            runtime = rt
            await perform(actions)
        }
    }

    // MARK: Following objects

    /// Re-measures the objects Pip is pointing at, so outlines follow objects that moved and snap
    /// back onto them when the user returns to the room.
    private func refreshTick() async {
        guard !refreshing, !lookActive, ar.trackingNormal, let snapshot = ar.snapshot() else { return }
        let targets = ar.visibleMarkBoxes(in: snapshot).prefix(3)
        guard !targets.isEmpty else { return }
        refreshing = true
        defer { refreshing = false }
        let grounder = Grounder(client: client, frameJPEG: Data())
        await withTaskGroup(of: (Int, CGRect, SegmentInstance?).self) { group in
            for t in targets {
                group.addTask { (t.id, t.box, await grounder.reground(box: t.box, id: t.id, frame: snapshot.image)) }
            }
            for await (id, box, inst) in group {
                guard let inst, !lookActive else { continue }
                // Only the same object: it overlaps where the mark was and has a similar size.
                let overlap = box.intersection(inst.boxRect)
                let area = Double(box.width * box.height), newArea = Double(inst.boxRect.width * inst.boxRect.height)
                guard !overlap.isNull, Double(overlap.width * overlap.height) > 0.25 * min(area, newArea),
                      newArea > 0.4 * area, newArea < 2.5 * area else { continue }
                let moved = hypot(inst.boxRect.midX - box.midX, inst.boxRect.midY - box.midY) > 0.08 * max(box.width, box.height)
                let iou = Double(overlap.width * overlap.height) / (area + newArea - Double(overlap.width * overlap.height))
                // Small differences are measurement noise: keep the outline still.
                guard moved || iou < 0.85 else { continue }
                if ar.updateMark(inst, snapshot: snapshot) { log("mark \(id % 1000) re-measured" + (moved ? ": the object moved" : "")) }
            }
        }
    }
}
