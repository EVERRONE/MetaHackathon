import Foundation
import Testing
@testable import PipCore

private func gated() -> Procedure {
    Procedure(
        title: "Reset a breaker", goal: "power back", source: .init(kind: .none),
        objects: [.init(id: "b", name: "breaker", phrase: "breaker")],
        steps: [
            .init(id: "1", instruction: "Find the breaker.", targets: ["b"], check: .init(kind: .camera, expected: "breaker visible")),
            .init(id: "2", instruction: "Remove the cover.", check: .init(kind: .camera, expected: "cover off"), gate: "the power is off"),
            .init(id: "3", instruction: "Switch on and test.", check: .init(kind: .user, expected: "light works")),
        ])
}

@Suite struct CommandNegationTests {
    @Test func negationsAreNeverYesOrDone() {
        for no in ["it is not", "klopt niet", "dat klopt niet", "not right", "that's not right", "nog niet klaar", "ik ben nog niet klaar",
                   "not done yet", "nog niet gedaan", "it’s not done", "nee", "Nee, nog niet"] {
            #expect(Command.parse(no) == .no, "\(no)")
        }
        // A no with more to it goes to the model.
        #expect(Command.parse("nee, de linker") == nil)
    }

    @Test func questionsAndPlacesGoToTheModel() {
        for q in ["left or right?", "the right one?", "klopt dat?", "ja maar welke?", "next to the sink?", "do I put it back?",
                  "the back one?", "terug naar stap 2", "put it back", "is it the right one"] {
            #expect(Command.parse(q) == nil, "\(q)")
        }
    }

    @Test func plainCommands() {
        #expect(Command.parse("Stop!") == .pause)
        #expect(Command.parse("wacht") == .pause)
        #expect(Command.parse("stop de taak") == .stop)
        #expect(Command.parse("ga verder") == .resume)
        #expect(Command.parse("ja, klaar") == .done)
        #expect(Command.parse("right") == .yes)
        #expect(Command.parse("that's right") == .yes)
        #expect(Command.parse("what was it?") == .repeatStep)
    }
}

@Suite struct RuntimeGateTests {
    @Test func noToAGateKeepsAskingUntilYes() {
        var r = ProcedureRuntime(procedure: gated())
        _ = r.handle(.start)
        _ = r.handle(.userDone)
        _ = r.handle(.verified(seen: true, confidence: 0.9))
        #expect(r.expectsAnswer)
        #expect(r.handle(.answer(false)) == [])
        #expect(r.expectsAnswer)
        #expect(r.handle(.answer(true)) == [.instruct(step: 1)])
    }

    @Test func repeatOrBackWhileGatedAsksTheGateAgain() {
        var r = ProcedureRuntime(procedure: gated())
        _ = r.handle(.start)
        _ = r.handle(.userDone)
        _ = r.handle(.verified(seen: true, confidence: 0.9))
        #expect(r.handle(.repeatStep) == [.askGate(step: 1, condition: "the power is off")])
        // Confirm, do the step, then go back: the gate is asked again.
        _ = r.handle(.answer(true))
        _ = r.handle(.userDone)
        _ = r.handle(.verified(seen: true, confidence: 0.9))
        #expect(r.index == 2)
        #expect(r.handle(.back) == [.askGate(step: 1, condition: "the power is off")])
    }

    @Test func anInterruptedCheckWaitsForTheUserAgain() {
        var r = ProcedureRuntime(procedure: gated())
        _ = r.handle(.start)
        #expect(r.handle(.userDone) == [.verify(step: 0)])
        _ = r.handle(.interrupted)
        #expect(r.statuses[0] == .awaitingAction)
        #expect(r.handle(.userDone) == [.verify(step: 0)])
    }

    @Test func theOpenQuestionCanBeAskedAgain() {
        var r = ProcedureRuntime(procedure: gated())
        _ = r.handle(.start)
        #expect(r.pendingQuestionAction == nil)
        _ = r.handle(.userDone)
        _ = r.handle(.verified(seen: true, confidence: 0.9))
        #expect(r.pendingQuestionAction == .askGate(step: 1, condition: "the power is off"))
    }

    @Test func anOfferedTaskIsNotActiveUntilStarted() {
        var r = ProcedureRuntime(procedure: gated())
        #expect(!r.isActive)
        #expect(r.handle(.resume) == [])
        #expect(r.handle(.start) == [.instruct(step: 0)])
        #expect(r.isActive)
        #expect(r.handle(.start) == [])
    }

    @Test func repeatWhileAResultQuestionIsPendingStartsTheStepAgain() {
        var r = ProcedureRuntime(procedure: gated())
        _ = r.handle(.start)
        _ = r.handle(.userDone)
        _ = r.handle(.verified(seen: false, confidence: 0.9))
        _ = r.handle(.userDone)
        _ = r.handle(.verified(seen: false, confidence: 0.9))
        #expect(r.expectsAnswer)
        #expect(r.handle(.repeatStep) == [.instruct(step: 0)])
        #expect(!r.expectsAnswer)
    }
}

@Suite struct SafetyWordTests {
    @Test func harmlessSentencesAreNoHazard() {
        for s in ["Ik wil een rookmelder ophangen", "replace the battery in the smoke alarm", "ja, het brandt", "het brandt nog steeds niet",
                  "ik rook niks", "change the spark plug", "geen rook", "there's no smoke", "it's crooked", "sparkling water", "smoked salmon"] {
            #expect(SafetyPolicy.spokenHazard(in: s) == nil, "\(s)")
        }
    }

    @Test func realHazardsAreCaught() {
        #expect(SafetyPolicy.spokenHazard(in: "Er komt rook uit de kast") == "rook")
        #expect(SafetyPolicy.spokenHazard(in: "I’m hurt") == "i'm hurt")
        #expect(SafetyPolicy.spokenHazard(in: "there are sparks coming out") == "sparks")
        #expect(SafetyPolicy.spokenHazard(in: "ik ruik gas") == "ruik gas")
    }

    @Test func classificationOnWholeWords() {
        for ok in ["hang a medicine cabinet", "medicijnkastje ophangen", "wasmiddel doseren", "in verband met de verhuis een kast bouwen",
                   "remove the remains of the sealant", "install doorbell wiring"] {
            #expect(SafetyPolicy.classify(ok) == .allowed, "\(ok)")
        }
        for mains in ["replace the outlet", "Vervang het stopcontact", "replace a light switch", "install a ceiling light"] {
            #expect(SafetyPolicy.classify(mains) == .refused(reason: "mains"), "\(mains)")
        }
        #expect(SafetyPolicy.classify("lift the shelf onto the brackets") == .allowed)
        #expect(SafetyPolicy.classify("De lift staat in storing") == .allowedWithGates)
        #expect(SafetyPolicy.classify("stroomuitval in de keuken") == .allowedWithGates)
    }
}

@Suite struct CompilerSafetyTests {
    @Test func gatedPlansAlwaysGetASafetyQuestion() throws {
        let json = """
        {"title":"Reset the breaker","classification":"allowed_with_gates","refusal_reason":"","objects":[],
         "steps":[{"instruction":"Push the lever up.","why":"","targets":[],"check_kind":"camera","expected":"lever up","cautions":[],"gate":"","source_ref":""}],
         "cautions":[],"mismatch":""}
        """
        let raw = try JSONDecoder().decode(ProcedureCompiler.RawProcedure.self, from: Data(json.utf8))
        let compiled = try raw.compiled(goal: "reset the breaker", source: .none, seconds: 0)
        #expect(compiled.classification == .allowedWithGates)
        #expect(compiled.procedure.steps[0].gate != nil)
    }

    @Test func refusalReasonsAreKnownWords() throws {
        let json = """
        {"title":"","classification":"refused","refusal_reason":"gas","objects":[],"steps":[],"cautions":[],"mismatch":""}
        """
        let raw = try JSONDecoder().decode(ProcedureCompiler.RawProcedure.self, from: Data(json.utf8))
        #expect(try raw.compiled(goal: "fix the cooker", source: .none, seconds: 0).classification == .refused(reason: "gas"))
    }

    @Test func firstJSONObjectSkipsBracesInStrings() {
        #expect(ProcedureCompiler.firstJSONObject(in: #"Here: {"a":"}{","b":{"c":1}} done"#) == #"{"a":"}{","b":{"c":1}}"#)
    }
}

@Suite struct MemorySearchSampleTests {
    @Test func searchesTheWholeWindow() {
        #expect(MemorySearch.sample(count: 10, max: 192) == Array(0..<10))
        let picked = MemorySearch.sample(count: 600, max: 192)
        #expect(picked.count == 192)
        #expect(picked.first == 0)
        #expect(picked.last == 599)
        #expect(picked == picked.sorted())
        #expect(Set(picked).count == 192)
    }
}

@Suite struct CueTagListTests {
    @Test func spacedListsJoinOnlyOutsideQuotes() {
        #expect(CueTag.parse("candidates m=3, 4")?.attributes["m"] == "3,4")
        #expect(CueTag.parse(#"remember key="spot" value="shelf 2, 3rd row" from=said"#)?.attributes["value"] == "shelf 2, 3rd row")
    }
}
