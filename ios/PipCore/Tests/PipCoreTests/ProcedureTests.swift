import Foundation
import Testing
@testable import PipCore

private func sample(gate: String? = nil) -> Procedure {
    Procedure(
        title: "Reset a tripped breaker",
        goal: "power back in the kitchen",
        source: .init(kind: .none),
        objects: [.init(id: "b", name: "kitchen breaker", phrase: "breaker", text: ["B6"]), .init(id: "rcd", name: "RCD", phrase: "switch")],
        steps: [
            .init(id: "1", instruction: "Find the breaker that is down.", targets: ["b"], check: .init(kind: .camera, expected: "breaker B6 is visible")),
            .init(id: "2", instruction: "Push the lever up.", targets: ["b"], check: .init(kind: .camera, expected: "lever up"), gate: gate),
            .init(id: "3", instruction: "Check the kitchen lights.", check: .init(kind: .user, expected: "the lights work")),
            .init(id: "4", instruction: "Close the panel.", check: .init(kind: .none, expected: "panel closed")),
        ])
}

@Suite struct ProcedureRuntimeTests {
    @Test func walksThroughStepsOnlyWithEvidence() {
        var r = ProcedureRuntime(procedure: sample())
        #expect(r.handle(.start) == [.instruct(step: 0)])
        _ = r.handle(.instructed)
        #expect(r.handle(.userDone) == [.verify(step: 0)])
        // Not seen clearly: no progress.
        #expect(r.handle(.verified(seen: true, confidence: 0.5)) == [])
        #expect(r.index == 0)
        _ = r.handle(.userDone)
        #expect(r.handle(.verified(seen: true, confidence: 0.9)) == [.stepDone(step: 0, outcome: .cameraVerified), .instruct(step: 1)])
        _ = r.handle(.userDone)
        _ = r.handle(.verified(seen: true, confidence: 0.95))
        // Step 3 cannot be seen: the user is asked.
        #expect(r.handle(.userDone) == [.askResult(step: 2, expected: "the lights work")])
        #expect(r.handle(.answer(true)) == [.stepDone(step: 2, outcome: .userConfirmed), .instruct(step: 3)])
        // Step 4 cannot be checked at all.
        #expect(r.handle(.userDone) == [.cannotCheck(step: 3, expected: "panel closed"), .stepDone(step: 3, outcome: .notVerifiable), .finished])
        #expect(r.mode == .finished)
        #expect(r.doneCount == 4)
    }

    @Test func asksTheUserAfterTwoFailedLooks() {
        var r = ProcedureRuntime(procedure: sample())
        _ = r.handle(.start)
        _ = r.handle(.userDone)
        #expect(r.handle(.verified(seen: false, confidence: 0.9)) == [])
        _ = r.handle(.userDone)
        #expect(r.handle(.verified(seen: false, confidence: 0.9)) == [.askResult(step: 0, expected: "breaker B6 is visible")])
        #expect(r.expectsAnswer)
        #expect(r.handle(.answer(false)) == [.instruct(step: 0)])
    }

    @Test func gateMustBeConfirmedBeforeTheStep() {
        var r = ProcedureRuntime(procedure: sample(gate: "your hands are dry"))
        _ = r.handle(.start)
        _ = r.handle(.userDone)
        #expect(r.handle(.verified(seen: true, confidence: 0.9)) == [.stepDone(step: 0, outcome: .cameraVerified), .askGate(step: 1, condition: "your hands are dry")])
        // Done before the gate is confirmed does nothing.
        #expect(r.handle(.userDone) == [])
        #expect(r.handle(.answer(true)) == [.instruct(step: 1)])
    }

    @Test func hazardStopsEverything() {
        var r = ProcedureRuntime(procedure: sample())
        _ = r.handle(.start)
        #expect(r.handle(.hazard("smoke")) == [.stopped(reason: "smoke")])
        #expect(r.handle(.userDone) == [])
        #expect(r.handle(.start) == [])
    }

    @Test func backPauseAndSkip() {
        var r = ProcedureRuntime(procedure: sample())
        _ = r.handle(.start)
        _ = r.handle(.skip)
        #expect(r.index == 1)
        #expect(r.handle(.back) == [.instruct(step: 0)])
        #expect(r.handle(.pause) == [.paused])
        #expect(r.handle(.userDone) == [])
        #expect(r.handle(.resume) == [.resumed, .instruct(step: 0)])
    }

    @Test func procedureProblemsAreFound() {
        var p = sample()
        p.steps[1].targets = ["ghost"]
        #expect(p.problems() == ["step 2 targets unknown object ghost"])
    }
}

@Suite struct CommandTests {
    @Test func recognisesShortCommandsInBothLanguages() {
        #expect(Command.parse("Klaar.") == .done)
        #expect(Command.parse("ok, done") == .done)
        #expect(Command.parse("Volgende stap") == .done)
        #expect(Command.parse("Ga terug") == .back)
        #expect(Command.parse("herhaal dat eens") == .repeatStep)
        #expect(Command.parse("Ja") == .yes)
        #expect(Command.parse("nee, nog niet") == .no)
        #expect(Command.parse("wacht even") == .pause)
    }

    @Test func questionsAreNotCommands() {
        #expect(Command.parse("Welke schroef moet ik nu nemen voor het paneel?") == nil)
        #expect(Command.parse("Ja maar welke is het nu precies") == nil)
        #expect(Command.parse("") == nil)
    }
}

@Suite struct SafetyPolicyTests {
    @Test func classifiesTasks() {
        #expect(SafetyPolicy.classify("Ik wil mijn koffiemachine ontkalken") == .allowed)
        #expect(SafetyPolicy.classify("De automaat van de keuken is gesprongen") == .allowedWithGates)
        #expect(SafetyPolicy.classify("Ik wil een stopcontact vervangen") == .refused(reason: "mains"))
        #expect(SafetyPolicy.classify("How much insulin should I take?") == .refused(reason: "medical"))
    }

    @Test func spokenHazardsAreCaught() {
        #expect(SafetyPolicy.spokenHazard(in: "Er komt rook uit de kast") == "rook")
        #expect(SafetyPolicy.spokenHazard(in: "Alles werkt weer") == nil)
    }
}
