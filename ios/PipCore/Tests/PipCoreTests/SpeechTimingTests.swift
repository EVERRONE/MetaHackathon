import Foundation
import Testing
@testable import PipCore

/// Streamed speech times a cue only once its word's time has arrived; whole speech always has one.
@Suite struct SpeechTimingTests {
    @Test func aWordIsTimedOnlyOnceItsTimeArrived() {
        let text = "Press the pause key"
        // The first ten characters' times have streamed in so far.
        let partial = SpokenAudio(pcm: Data(), characters: text.prefix(10).map(String.init), starts: (0..<10).map { Double($0) * 0.05 })
        let press = 0, pause = (text as NSString).range(of: "pause").location
        #expect(partial.knownStartTime(atUTF16: press, in: text) == 0)
        #expect(partial.knownStartTime(atUTF16: pause, in: text) == nil)
        // The nearest known time is still given when the whole sentence is in (the end of a stream).
        #expect(partial.startTime(atUTF16: pause, in: text) == 0.45)
        let whole = SpokenAudio(pcm: Data(), characters: text.map(String.init), starts: (0..<text.count).map { Double($0) * 0.05 })
        #expect(whole.knownStartTime(atUTF16: pause, in: text) == Double(pause) * 0.05)
    }
}
