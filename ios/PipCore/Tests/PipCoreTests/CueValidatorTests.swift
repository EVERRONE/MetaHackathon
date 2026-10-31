import Testing
@testable import PipCore

@Suite struct CueValidatorTests {
    let marks: [Int: MarkInfo] = [
        1: MarkInfo(id: 1, confidence: 0.9),
        2: MarkInfo(id: 2, confidence: 0.3),
        3: MarkInfo(id: 3, confidence: 0.7),
    ]
    let validator = CueValidator(minConfidence: 0.45)

    @Test func acceptsConfidentOutline() {
        #expect(validator.validate(.outline(mark: 1), marks: marks, hasEvidence: { _ in false }) == .accept(.outline(mark: 1)))
    }

    @Test func downgradesLowConfidenceToCandidates() {
        let d = validator.validate(.move(mark: 2, direction: .up), marks: marks, hasEvidence: { _ in false })
        #expect(d.cue == .candidates(marks: [2]))
    }

    @Test func rejectsUnknownMarks() {
        #expect(validator.validate(.outline(mark: 9), marks: marks, hasEvidence: { _ in true }).cue == nil)
    }

    @Test func verifiedNeedsEvidence() {
        #expect(validator.validate(.verified(mark: 1), marks: marks, hasEvidence: { _ in false }).cue == nil)
        #expect(validator.validate(.verified(mark: 1), marks: marks, hasEvidence: { $0 == 1 }).cue == .verified(mark: 1))
    }

    @Test func dangerAlwaysShows() {
        #expect(validator.validate(.danger(mark: 42, reason: "water"), marks: marks, hasEvidence: { _ in false }).cue == .danger(mark: nil, reason: "water"))
    }

    @Test func candidatesDropUnknownMarks() {
        #expect(validator.validate(.candidates(marks: [1, 7, 3]), marks: marks, hasEvidence: { _ in false }).cue == .candidates(marks: [1, 3]))
    }
}

@Suite struct AnnotationBoardTests {
    @Test func transientCuesFade() {
        var board = AnnotationBoard()
        board.show(.outline(mark: 1), at: 0)
        board.tick(AnnotationBoard.transientSeconds - 0.1)
        #expect(board.annotations.count == 1)
        board.tick(AnnotationBoard.transientSeconds)
        #expect(board.annotations.isEmpty)
    }

    @Test func actionCuesStayUntilVerified() {
        var board = AnnotationBoard()
        board.show(.move(mark: 1, direction: .up), at: 0)
        board.tick(60)
        #expect(board.annotations.count == 1)
        board.show(.verified(mark: 1), at: 61)
        #expect(board.annotations.map(\.cue) == [.verified(mark: 1)])
    }

    @Test func atMostThreeMarksAndDangerIsNeverEvicted() {
        var board = AnnotationBoard()
        board.show(.danger(mark: 9, reason: "hot"), at: 0)
        board.show(.outline(mark: 1), at: 1)
        board.show(.outline(mark: 2), at: 1.1)
        board.show(.outline(mark: 3), at: 1.2)
        #expect(board.activeMarks == [9, 2, 3])
        board.show(.clear, at: 2)
        #expect(board.annotations.map(\.cue) == [.danger(mark: 9, reason: "hot")])
    }

    @Test func newCueReplacesSameFamilyOnSameMark() {
        var board = AnnotationBoard()
        board.show(.move(mark: 1, direction: .up), at: 0)
        board.show(.rotate(mark: 1, direction: .cw, amount: .quarter), at: 1)
        #expect(board.annotations.map(\.cue) == [.rotate(mark: 1, direction: .cw, amount: .quarter)])
    }
}

@Suite struct ChatChunkDecoderTests {
    @Test func decodesDeltasFinishAndUsage() {
        let d = ChatChunkDecoder()
        #expect(d.events(forLine: #"data: {"choices":[{"delta":{"content":"Hi"},"index":0}]}"#) == [.delta("Hi")])
        let last = d.events(forLine: #"data: {"choices":[{"delta":{},"finish_reason":"stop","index":0}],"usage":{"completion_tokens":7,"prompt_tokens":15,"prompt_tokens_details":{"cached_tokens":0}}}"#)
        #expect(last.first == .finished(reason: "stop"))
        if case .usage(let u) = last.last { #expect(u.promptTokens == 15 && u.completionTokens == 7) } else { Issue.record("no usage") }
        #expect(d.events(forLine: "data: [DONE]").isEmpty)
        #expect(d.events(forLine: ": keep-alive").isEmpty)
    }
}
