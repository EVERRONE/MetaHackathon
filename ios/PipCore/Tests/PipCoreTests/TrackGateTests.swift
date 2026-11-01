import Testing
import simd
@testable import PipCore

/// A followed object must not jump to a look-alike (see TrackGate).
@Suite struct TrackGateTests {
    static let key = SIMD3<Float>(-0.023, -0.088, -0.208)

    /// A still key, masks every 0.1 s with a millimetre of noise.
    static func still(_ gate: inout TrackGate, for seconds: Double, from t0: Double = 0) -> Double {
        var t = t0
        var k = 0
        while t < t0 + seconds {
            let noise = SIMD3<Float>(Float(k % 3) * 0.001, 0, Float(k % 2) * 0.001)
            #expect(gate.judge(time: t, position: key + noise, lockHeld: false) == .accept)
            t += 0.1
            k += 1
        }
        return t
    }

    @Test func aLookAlikeNextToAStillKeyIsIgnored() {
        var gate = TrackGate()
        var t = Self.still(&gate, for: 1)
        #expect(gate.anchor != nil)
        // 1 Nov, 12:07:03: after a fast turn the mask was on a key 5 cm away, then 15 cm.
        for p in [Self.key + SIMD3(0.04, 0, 0.05), Self.key + SIMD3(0.155, -0.013, 0.039)] {
            if case .reject(let d) = gate.judge(time: t, position: p, lockHeld: true) { #expect(d > 0.03) } else { Issue.record("taken") }
            t += 0.1
        }
        #expect(gate.uncertain)
        // The right key again: taken, and certain again.
        #expect(gate.judge(time: t, position: Self.key, lockHeld: true) == .accept)
        #expect(!gate.uncertain)
    }

    @Test func aLockedObjectNeverMovesOnEdgeTAMsWord() {
        var gate = TrackGate()
        var t = Self.still(&gate, for: 1)
        for _ in 0..<20 {
            #expect(gate.judge(time: t, position: Self.key + SIMD3(0.05, 0, 0), lockHeld: true) != .moved)
            t += 0.1
        }
    }

    @Test func anObjectPutDownElsewhereIsFollowedThere() {
        var gate = TrackGate()
        var t = Self.still(&gate, for: 1)
        // Picked up and put down 20 cm away faster than the masks: five masks agree on it.
        let there = Self.key + SIMD3(0.2, 0, 0)
        var verdicts: [TrackGate.Verdict] = []
        for _ in 0..<5 {
            verdicts.append(gate.judge(time: t, position: there, lockHeld: false))
            t += 0.1
        }
        #expect(verdicts.dropLast().allSatisfy { if case .reject = $0 { return true } else { return false } })
        #expect(verdicts.last == .moved)
        #expect(gate.judge(time: t, position: there, lockHeld: false) == .accept)
    }

    @Test func anObjectMovedByHandIsFollowedAllTheWay() {
        var gate = TrackGate()
        var t = Self.still(&gate, for: 1)
        // Slid 30 cm at up to 0.5 m/s: each mask is a few centimetres on, never a jump from a
        // still place once it moves.
        var x: Float = 0
        var taken = 0
        for _ in 0..<12 {
            x += 0.025
            if gate.judge(time: t, position: Self.key + SIMD3(x, 0, 0), lockHeld: false) == .accept { taken += 1 }
            t += 0.1
        }
        #expect(taken == 12)
    }

    @Test func anObjectGrabbedFastIsFollowedFromTheThirdMask() {
        var gate = TrackGate()
        var t = Self.still(&gate, for: 1)
        // 5 cm per mask from the start (0.5 m/s): the first two are held back, the third shows a
        // steady path away and is taken, and from then on it is followed.
        var verdicts: [TrackGate.Verdict] = []
        for k in 1...6 {
            verdicts.append(gate.judge(time: t, position: Self.key + SIMD3(Float(k) * 0.05, 0, 0), lockHeld: false))
            t += 0.1
        }
        #expect(verdicts[0] != .accept && verdicts[1] != .accept)
        #expect(verdicts[2] == .moved)
        #expect(verdicts[3...].allSatisfy { $0 == .accept })
    }

    @Test func aLookAlikeThatStaysPutIsNotAPath() {
        var gate = TrackGate()
        var t = Self.still(&gate, for: 1)
        // The neighbouring key, 4 cm away, mask after mask (with a millimetre of noise).
        for k in 0..<4 {
            let v = gate.judge(time: t, position: Self.key + SIMD3(0.04 + Float(k % 2) * 0.001, 0, 0), lockHeld: false)
            #expect(v != .moved && v != .accept)
            t += 0.1
        }
    }

    /// The masks of 1 Nov 12:07:03-12:07:05, after the Windows key was lost in a fast turn: a
    /// leap 16 cm away, then a steady slide along the neighbouring keys. Not taken, even without
    /// the keyboard's lock.
    @Test func afterALossTheSlideAlongTheKeysIsNotTaken() {
        var gate = TrackGate()
        var t = Self.still(&gate, for: 1)
        let logged: [SIMD3<Float>] = [SIMD3(0.1324, -0.1013, -0.1694), SIMD3(0.0040, -0.0883, -0.1683), SIMD3(0.0168, -0.0877, -0.1572),
                                      SIMD3(0.0294, -0.0877, -0.1509), SIMD3(0.0442, -0.0887, -0.1477), SIMD3(0.0411, -0.0892, -0.1562),
                                      SIMD3(0.0274, -0.0900, -0.1739), SIMD3(0.0118, -0.0877, -0.1876)]
        for p in logged {
            let v = gate.judge(time: t, position: p, lockHeld: false, recentlyLost: true)
            #expect(v != .accept && v != .moved)
            t += 0.15
        }
        // Without the loss, the same slide would have looked like the object being carried off.
        var naive = TrackGate()
        var t2 = Self.still(&naive, for: 1)
        var taken = false
        for p in logged {
            if naive.judge(time: t2, position: p, lockHeld: false) == .moved { taken = true }
            t2 += 0.15
        }
        #expect(taken)
    }

    /// 1 Nov, 12:27: the POWER button's mask (0.1 % of the frame) alternated with one of half the
    /// remote (5 %). Those are not taken; coming closer (the button growing steadily) is.
    @Test func aMaskOfSomethingFarBiggerIsNotTaken() {
        var gate = TrackGate()
        var t = 0.0
        for _ in 0..<6 {
            #expect(gate.judge(time: t, position: Self.key, area: 0.001, lockHeld: false) == .accept)
            t += 0.1
        }
        if case .reject = gate.judge(time: t, position: Self.key + SIMD3(0.005, 0, 0), area: 0.05, lockHeld: false) {} else { Issue.record("taken") }
        t += 0.1
        #expect(gate.judge(time: t, position: Self.key, area: 0.0011, lockHeld: false) == .accept)
        t += 0.1
        // Closer and closer: three times the size, mask after mask, is taken from the fifth on.
        var taken = 0
        for _ in 0..<8 {
            if gate.judge(time: t, position: Self.key, area: 0.0033, lockHeld: false) == .accept { taken += 1 }
            t += 0.1
        }
        #expect(taken >= 4)
    }

    @Test func anImpossibleLeapWhileMovingIsAGlitch() {
        var gate = TrackGate()
        var t = 0.0
        for k in 0..<5 {
            #expect(gate.judge(time: t, position: Self.key + SIMD3(Float(k) * 0.03, 0, 0), lockHeld: false) == .accept)
            t += 0.1
        }
        // 60 cm in a tenth of a second.
        if case .reject = gate.judge(time: t, position: Self.key + SIMD3(0.72, 0, 0), lockHeld: false) {} else { Issue.record("taken") }
    }
}
