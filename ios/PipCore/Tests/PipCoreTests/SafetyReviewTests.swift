import Testing
@testable import PipCore

/// Findings of the code review of 1 Nov on yes-answers, gates and spoken hazards: each was
/// reproduced first, then fixed.
@Suite struct SafetyReviewTests {
    @Test func aHedgedOrNegatedYesIsNoYes() {
        for text in ["Yeah, I don't think so", "Yes, the power isn't off yet", "Yes, it's still on", "Okay, let me check",
                     "Oké, even kijken", "Ja, maar de stroom staat nog aan", "Yes, but wait", "Okay, I can't find it"] {
            #expect(!Utterance.startsWithYes(text), "\(text)")
        }
        for text in ["Yes, I'm in Settings now", "Ja, de stroom is uit", "Yeah, the breaker is down now", "Okay, doe maar",
                     "Oké dan", "Ok, let's go", "Ja hoor, hij is uit", "Prima, begin maar", "Oké, start maar", "Yes please"] {
            #expect(Utterance.startsWithYes(text), "\(text)")
        }
    }

    static func gatedPlan() -> Procedure {
        Procedure(title: "Replace the socket cover", goal: "replace the cover", source: Procedure.Source(kind: .none, reference: nil), objects: [],
                  steps: [Procedure.Step(id: "1", instruction: "Remove the cover.", why: nil, targets: [], check: Procedure.Check(kind: .user, expected: "cover off"),
                                         cautions: [], gate: "The power is off at the breaker", sourceRef: nil),
                          Procedure.Step(id: "2", instruction: "Disconnect the wires.", why: nil, targets: [], check: Procedure.Check(kind: .user, expected: "wires loose"),
                                         cautions: [], gate: nil, sourceRef: nil)],
                  cautions: [])
    }

    @Test func aSafetyQuestionCannotBeSkipped() {
        var rt = ProcedureRuntime(procedure: Self.gatedPlan())
        #expect(rt.handle(.start) == [.askGate(step: 0, condition: "The power is off at the breaker")])
        // "Skip" while the safety question is open skips the step, not the question: the next
        // step needs the power off as much.
        #expect(rt.handle(.skip) == [.stepDone(step: 0, outcome: .skipped), .askGate(step: 1, condition: "The power is off at the breaker")])
        #expect(rt.handle(.userDone) == [])
        #expect(rt.handle(.answer(true)) == [.instruct(step: 1)])
    }

    @Test func aConfirmedStepCanBeSkipped() {
        var rt = ProcedureRuntime(procedure: Self.gatedPlan())
        _ = rt.handle(.start)
        #expect(rt.handle(.answer(true)) == [.instruct(step: 0)])
        #expect(rt.handle(.skip) == [.stepDone(step: 0, outcome: .skipped), .instruct(step: 1)])
    }

    @Test func aDoneSaidDuringTheInstructionIsKept() {
        var plan = Self.gatedPlan()
        plan.steps[0].gate = nil
        plan.steps[0].check = Procedure.Check(kind: .camera, expected: "cover off")
        var rt = ProcedureRuntime(procedure: plan)
        _ = rt.handle(.start)
        // "Klaar" while Pip was still giving the step: the check starts, and its result counts
        // (the instruction's end used to set the step back to waiting, and the result was dropped).
        #expect(rt.handle(.userDone) == [.verify(step: 0)])
        let after = rt.handle(.verified(seen: true, confidence: 0.95))
        #expect(after.contains(.stepDone(step: 0, outcome: .cameraVerified)))
    }

    @Test func hazardsThatWereMissed() {
        for text in ["Het ruikt naar gas", "It smells like gas", "I smell burning", "It's smoking", "I got shocked",
                     "Het rookt hier", "Ik ruik iets branden"] {
            #expect(SafetyPolicy.spokenHazard(in: text) != nil, "\(text)")
        }
    }

    @Test func aNegationOnlyCountsRightAtTheHazard() {
        // Still a hazard: the negation is about something else.
        for text in ["De rook gaat niet weg", "De vonken stoppen niet", "Ik weet niet waarom het vonkt", "It is not stopping, there is smoke"] {
            #expect(SafetyPolicy.spokenHazard(in: text) != nil, "\(text)")
        }
        // Calm: the hazard itself is denied.
        for text in ["Geen rook", "There's no smoke", "Ik ruik niks", "Het vonkt niet", "No sparks at all", "There isn't any smoke", "Geen enkele vonk"] {
            #expect(SafetyPolicy.spokenHazard(in: text) == nil, "\(text)")
        }
    }
}
