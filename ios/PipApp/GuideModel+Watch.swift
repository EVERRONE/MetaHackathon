import Foundation
import PipCore
import simd

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
        Timer.scheduledTimer(withTimeInterval: Self.watchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.watchTick() }
        }
        Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
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
        if Utterance.words(text).contains("pip") {
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
        guard let result = try? await StepChecker(client: client).check(snapshot.image, step: context, focus: focus), !Task.isCancelled else { return }
        log(String(format: "watch step %d: %@ %.2f %@ · problem %@ %.2f %@", index + 1, result.done ? "done" : "not yet", result.confidence, result.seen,
                   result.problem.rawValue, result.problemConfidence, result.problemText))
        // The user started talking during the check: their turn goes first, not "well done".
        guard let now = runtime, now.index == index, now.statuses[index] == .awaitingAction, !lookActive, !speaker.isSpeaking, phase != .hearing else { return }

        // A mistake seen twice in a row is checked by Wonder, which corrects the user and points at
        // the right object, or stays silent when it was a false alarm.
        if result.problem != .none, result.problemConfidence >= 0.75, !result.done, Date() > problemQuietUntil {
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
        await look("(watching step \(index + 1))", snapshot: snapshot, started: Date(), directive: directive, lookups: false)
        let spoke = !spokenThisTurn.isEmpty
        log(spoke ? "corrected: \(problem.problemText)" : "false alarm: \(problem.problemText)")
        // After a false alarm (or a correction) the quick checks stay quiet for a while, so one
        // recurring misreading does not cost a Wonder look every few seconds.
        problemQuietUntil = Date().addingTimeInterval(spoke ? 15 : 45)
        if spoke, problem.problem == .hazard, var rt = runtime, rt.isActive {
            let actions = rt.handle(.hazard(problem.problemText))
            runtime = rt
            await perform(actions)
        }
    }

    // MARK: Following objects

    /// Measures pointed-at objects again at the moments that matter (see `ObjectTrack`): when one
    /// comes back into view it is found again from scratch (the full grounding, with its printed
    /// text), and the drift that shows is applied to the other objects in the room; from a new
    /// viewpoint it is re-measured and fused, so its position gets firmer with every view.
    /// (An image lock is checked against EdgeTAM's mask of the same frame: ARController.lockComparison.
    /// Re-segmenting where the lock draws, as before, only ever confirmed the lock.)
    private func refreshTick() async {
        guard !refreshing, !lookActive, ar.trackingNormal, ar.hasPointedMarks, let snapshot = ar.snapshot() else { return }
        let candidates = ar.remeasureCandidates(in: snapshot, taskActive: runtime?.isActive == true)
        guard !candidates.isEmpty else { return }
        refreshing = true
        defer { refreshing = false }
        let refind = candidates.contains { $0.reason == .reentry }
        let grounder = Grounder(client: client, frameJPEG: refind ? (SetOfMarks.jpeg(snapshot.image, quality: 0.8) ?? Data()) : Data())
        let specs = Dictionary(uniqueKeysWithValues: candidates.compactMap { c in
            c.reason == .reentry ? ar.spec(for: c.id, in: snapshot, box: c.box).map { (c.id, $0) } : nil
        })
        await withTaskGroup(of: (Int, CGRect, ObjectTrack.Reason, SegmentInstance?).self) { group in
            for c in candidates {
                let spec = specs[c.id]
                group.addTask {
                    if let spec { return (c.id, c.box, c.reason, await grounder.ground(spec, id: c.id, frame: snapshot.image).instance) }
                    return (c.id, c.box, c.reason, await grounder.reground(box: c.box, id: c.id, frame: snapshot.image))
                }
            }
            for await (id, box, reason, inst) in group {
                guard !lookActive, !Task.isCancelled else { continue }
                guard let inst, Self.sameObject(expected: box, found: inst.boxRect, reason: reason) else {
                    ar.measureFailed(id)
                    log("mark \(id % 1000) not found again (\(reason.rawValue))")
                    continue
                }
                guard let update = ar.updateMark(inst, snapshot: snapshot, reason: reason) else { continue }
                if let offset = update.offset { ar.shiftNeighbours(of: id, by: offset) }
                trackingLog.record(id: id, reason: reason, update: update)
                log(String(format: "mark %d %@: corrected %.1f cm (%.0f px), %d view%@%@", id % 1000, reason.rawValue, update.correction * 100,
                           update.pixelError ?? -1, update.views, update.views == 1 ? "" : "s",
                           update.reset ? (update.offset != nil ? String(format: ", drift %.0f cm", simd_length(update.offset!) * 100) : ", moved") : ""))
            }
        }
    }

    /// Keys waiting to be locked together (see `lockToObject`).
    struct PendingLock {
        var on: String?
        var snapshot: FrameSnapshot
        var keys: [(id: Int, key: SegmentInstance)] = []
        var generation = 0
    }

    /// The keys of one look ground within a second or two of each other: a lock waits this long
    /// after the last one for the others on the same object.
    static let lockGathering: TimeInterval = 1.5

    /// Makes a reference image of the object a mark is on and hands it to ARKit, which then
    /// follows the object in 3D with the outline on it. `on`: what the model said the target is
    /// part of ("remote control"); SAM finds that object around the key and its mask is the
    /// image. Without it, a tight patch around the key (on a device, mostly the device).
    /// Keys of one look on the same object share one lock: one picture of the object for ARKit to
    /// find, which then carries every key, and one re-run of the session (1 Nov: three nearly
    /// identical pictures of one keyboard, one per key, were never found, and the session's
    /// re-runs for them and their removal crashed ARKit).
    func lockToObject(_ id: Int, key: SegmentInstance, on: String?, snapshot: FrameSnapshot) {
        let group = on.map { "\(id / 1000)|\($0)" } ?? "\(id)"
        var pending = pendingLocks[group] ?? PendingLock(on: on, snapshot: snapshot)
        pending.keys.append((id, key))
        pending.generation += 1
        pendingLocks[group] = pending
        let generation = pending.generation
        Task { [weak self] in
            if on != nil { try? await Task.sleep(nanoseconds: UInt64(Self.lockGathering * 1_000_000_000)) }
            guard let self, let p = self.pendingLocks[group], p.generation == generation else { return }
            self.pendingLocks[group] = nil
            await self.makeLock(p)
        }
    }

    private func makeLock(_ p: PendingLock) async {
        guard let first = p.keys.first?.key.boxRect else { return }
        let snapshot = p.snapshot
        let bounds = CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height)
        let label = p.keys.map { String($0.id % 1000) }.joined(separator: ",")
        var parent: SegmentInstance?
        if let on = p.on {
            let object = await Grounder(client: client, frameJPEG: Data()).object(named: on, at: CGPoint(x: first.midX, y: first.midY), in: snapshot.image, id: 0)
            // The object the keys are on: it holds each of them, is clearly bigger, and is not the whole view.
            parent = object.flatMap { o -> SegmentInstance? in
                let keyArea = p.keys.map { Double($0.key.boxRect.width * $0.key.boxRect.height) }.max() ?? 0
                let holdsAll = p.keys.allSatisfy { Grounding.contains(o, CGPoint(x: $0.key.boxRect.midX, y: $0.key.boxRect.midY)) }
                return holdsAll && Double(o.area) >= 3 * keyArea && Double(o.area) < 0.7 * Double(bounds.width * bounds.height) ? o : nil
            }
        }
        let distance = snapshot.depth(atSensor: snapshot.sensorPoint(CGPoint(x: first.midX, y: first.midY)), minConfidence: 1) ?? 0.4
        guard let made = ImageLock.make(keys: p.keys.map(\.key), object: parent, snapshot: snapshot, distance: distance) else {
            log("lock: mark\(p.keys.count > 1 ? "s" : "") \(label): no region to lock to")
            return
        }
        log(String(format: "lock: mark%@ %@: reference %@ (%.0f mm), at %.2f m", p.keys.count > 1 ? "s" : "", label,
                   parent == nil ? "around the key" : "of their object", made.physicalWidth * 1000, distance))
        ar.lock(Dictionary(uniqueKeysWithValues: zip(p.keys.map(\.id), made.locals)), image: made.image, physicalWidth: made.physicalWidth)
    }

    /// An object Pip pointed at was moved (followed in the image) and lies still again: measure it
    /// at its new place and anchor it there.
    func remeasureMoved(_ id: Int, screenBox: CGRect) async {
        guard !refreshing, !lookActive, let snapshot = ar.snapshot(), let box = ar.snapshotBox(screen: screenBox, snapshot: snapshot),
              box.width > 4, box.height > 4 else { return }
        refreshing = true
        defer { refreshing = false }
        let grounder = Grounder(client: client, frameJPEG: Data())
        guard let inst = await grounder.reground(box: box, id: id, frame: snapshot.image),
              Self.sameObject(expected: box, found: inst.boxRect, reason: .check),
              let update = ar.updateMark(inst, snapshot: snapshot, reason: .check) else {
            log("mark \(id % 1000) moved, not measured again")
            return
        }
        trackingLog.record(id: id, reason: .check, update: update)
        log(String(format: "mark %d moved and settled: anchored again (%.0f cm away)", id % 1000, update.correction * 100))
    }

    /// Whether a fresh measurement is the same object: it overlaps where the outline was and has
    /// a similar size. Coming back after drift, it may be further off, but not in size.
    static func sameObject(expected box: CGRect, found: CGRect, reason: ObjectTrack.Reason) -> Bool {
        let area = Double(box.width * box.height), newArea = Double(found.width * found.height)
        guard area > 0, newArea > 0.4 * area, newArea < 2.5 * area else { return false }
        if reason == .reentry {
            return hypot(found.midX - box.midX, found.midY - box.midY) < 2.5 * max(box.width, box.height)
        }
        let overlap = box.intersection(found)
        return !overlap.isNull && Double(overlap.width * overlap.height) > 0.25 * min(area, newArea)
    }
}
