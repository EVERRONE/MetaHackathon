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
            #expect(gate.judge(time: t, position: key + noise) == .accept)
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
            if case .reject(let d) = gate.judge(time: t, position: p) { #expect(d > 0.03) } else { Issue.record("taken") }
            t += 0.1
        }
        #expect(gate.uncertain)
        // The right key again: taken, and certain again.
        #expect(gate.judge(time: t, position: Self.key) == .accept)
        #expect(!gate.uncertain)
    }

    @Test func anObjectPutDownElsewhereIsFollowedThere() {
        var gate = TrackGate()
        var t = Self.still(&gate, for: 1)
        // Picked up and put down 20 cm away faster than the masks: five masks agree on it.
        let there = Self.key + SIMD3(0.2, 0, 0)
        var verdicts: [TrackGate.Verdict] = []
        for _ in 0..<5 {
            verdicts.append(gate.judge(time: t, position: there))
            t += 0.1
        }
        #expect(verdicts.dropLast().allSatisfy { if case .reject = $0 { return true } else { return false } })
        #expect(verdicts.last == .moved)
        #expect(gate.judge(time: t, position: there) == .accept)
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
            if gate.judge(time: t, position: Self.key + SIMD3(x, 0, 0)) == .accept { taken += 1 }
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
            verdicts.append(gate.judge(time: t, position: Self.key + SIMD3(Float(k) * 0.05, 0, 0)))
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
            let v = gate.judge(time: t, position: Self.key + SIMD3(0.04 + Float(k % 2) * 0.001, 0, 0))
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
            let v = gate.judge(time: t, position: p, recentlyLost: true)
            #expect(v != .accept && v != .moved)
            t += 0.15
        }
        // Without the loss, the same slide would have looked like the object being carried off.
        var naive = TrackGate()
        var t2 = Self.still(&naive, for: 1)
        var taken = false
        for p in logged {
            if naive.judge(time: t2, position: p) == .moved { taken = true }
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
            #expect(gate.judge(time: t, position: Self.key, area: 0.001) == .accept)
            t += 0.1
        }
        if case .reject = gate.judge(time: t, position: Self.key + SIMD3(0.005, 0, 0), area: 0.05) {} else { Issue.record("taken") }
        t += 0.1
        #expect(gate.judge(time: t, position: Self.key, area: 0.0011) == .accept)
        t += 0.1
        // Closer and closer: three times the size, mask after mask, is taken from the fifth on.
        var taken = 0
        for _ in 0..<8 {
            if gate.judge(time: t, position: Self.key, area: 0.0033) == .accept { taken += 1 }
            t += 0.1
        }
        #expect(taken >= 4)
    }

    /// 3 Nov, 20:58:17-38: a washing machine's display (glossy black, 14 cm wide) followed while the
    /// user stepped back from 0.6 m to 0.86 m and a little aside (time, position, mask area). LiDAR
    /// read it 3-4 cm deeper from there; the display had not moved, and every mask lay on it (the
    /// kept frames show it). By position alone the gate refused masks (the outline was hidden)
    /// and then took it as moved; with the place it lay seen under the masks, every one is taken.
    static let display: [(Double, SIMD3<Float>, Float)] = [
        (0.00, SIMD3(0.4447, 0.0035, -0.4997), 0.0700),
        (0.25, SIMD3(0.4445, 0.0034, -0.4996), 0.0702),
        (0.50, SIMD3(0.4442, 0.0037, -0.4991), 0.0706),
        (0.75, SIMD3(0.4442, 0.0038, -0.4988), 0.0702),
        (1.00, SIMD3(0.4443, 0.0038, -0.4984), 0.0701),
        (1.25, SIMD3(0.4443, 0.0038, -0.4987), 0.0701),
        (1.50, SIMD3(0.4441, 0.0040, -0.4980), 0.0699),
        (1.75, SIMD3(0.4444, 0.0034, -0.4993), 0.0698),
        (2.00, SIMD3(0.4442, 0.0036, -0.4990), 0.0702),
        (2.25, SIMD3(0.4442, 0.0037, -0.4987), 0.0703),
        (2.50, SIMD3(0.4442, 0.0038, -0.4986), 0.0703),
        (2.75, SIMD3(0.4439, 0.0041, -0.4975), 0.0697),
        (3.00, SIMD3(0.4436, 0.0047, -0.4961), 0.0684),
        (3.20, SIMD3(0.4437, 0.0051, -0.4954), 0.0672),
        (3.40, SIMD3(0.4437, 0.0053, -0.4951), 0.0663),
        (3.60, SIMD3(0.4438, 0.0053, -0.4952), 0.0650),
        (3.80, SIMD3(0.4439, 0.0056, -0.4944), 0.0638),
        (4.00, SIMD3(0.4439, 0.0057, -0.4943), 0.0624),
        (4.25, SIMD3(0.4440, 0.0057, -0.4941), 0.0616),
        (4.50, SIMD3(0.4437, 0.0060, -0.4934), 0.0604),
        (4.75, SIMD3(0.4438, 0.0062, -0.4930), 0.0586),
        (5.00, SIMD3(0.4438, 0.0061, -0.4930), 0.0566),
        (5.25, SIMD3(0.4435, 0.0068, -0.4914), 0.0537),
        (5.50, SIMD3(0.4428, 0.0077, -0.4889), 0.0501),
        (5.75, SIMD3(0.4421, 0.0086, -0.4868), 0.0466),
        (6.00, SIMD3(0.4424, 0.0084, -0.4866), 0.0440),
        (6.11, SIMD3(0.4421, 0.0082, -0.4868), 0.0411),
        (6.22, SIMD3(0.4415, 0.0085, -0.4864), 0.0384),
        (6.33, SIMD3(0.4399, 0.0094, -0.4847), 0.0353),
        (6.44, SIMD3(0.4474, 0.0014, -0.5022), 0.0324),
        (6.56, SIMD3(0.4437, 0.0048, -0.4938), 0.0294),
        (6.67, SIMD3(0.4434, 0.0054, -0.4920), 0.0278),
        (6.78, SIMD3(0.4427, 0.0057, -0.4905), 0.0261),
        (6.89, SIMD3(0.4434, 0.0060, -0.4899), 0.0252),
        (7.00, SIMD3(0.4518, -0.0004, -0.5041), 0.0239),
        (7.11, SIMD3(0.4474, 0.0038, -0.4950), 0.0224),
        (7.22, SIMD3(0.4437, 0.0068, -0.4871), 0.0206),
        (7.33, SIMD3(0.4520, 0.0006, -0.5044), 0.0196),
        (7.44, SIMD3(0.4472, 0.0040, -0.4956), 0.0183),
        (7.56, SIMD3(0.4462, 0.0050, -0.4935), 0.0175),
        (7.67, SIMD3(0.4461, 0.0058, -0.4926), 0.0167),
        (7.78, SIMD3(0.4541, 0.0007, -0.5057), 0.0153),
        (7.89, SIMD3(0.4487, 0.0043, -0.4950), 0.0138),
        (8.00, SIMD3(0.4588, -0.0010, -0.5069), 0.0129),
        (8.12, SIMD3(0.4590, 0.0001, -0.5028), 0.0127),
        (8.25, SIMD3(0.4592, 0.0023, -0.4996), 0.0122),
        (8.38, SIMD3(0.4598, 0.0025, -0.4968), 0.0118),
        (8.50, SIMD3(0.4518, 0.0039, -0.4930), 0.0104),
        (8.62, SIMD3(0.4418, 0.0043, -0.4910), 0.0085),
        (8.75, SIMD3(0.4370, 0.0047, -0.4905), 0.0074),
        (8.88, SIMD3(0.4324, 0.0052, -0.4890), 0.0066),
        (9.00, SIMD3(0.4315, 0.0058, -0.4871), 0.0065),
        (9.11, SIMD3(0.4352, 0.0065, -0.4860), 0.0069),
        (9.22, SIMD3(0.4708, -0.0007, -0.5006), 0.0083),
        (9.33, SIMD3(0.4656, 0.0007, -0.4980), 0.0080),
        (9.44, SIMD3(0.4686, -0.0007, -0.5011), 0.0078),
        (9.56, SIMD3(0.4708, -0.0018, -0.5034), 0.0079),
        (9.67, SIMD3(0.4725, -0.0032, -0.5053), 0.0079),
        (9.78, SIMD3(0.4744, -0.0044, -0.5073), 0.0081),
        (9.89, SIMD3(0.4773, -0.0062, -0.5106), 0.0085),
        (10.00, SIMD3(0.4665, -0.0012, -0.5013), 0.0093),
        (10.17, SIMD3(0.4728, -0.0051, -0.5093), 0.0099),
        (10.33, SIMD3(0.4749, -0.0066, -0.5118), 0.0102),
        (10.50, SIMD3(0.4653, -0.0092, -0.5157), 0.0089),
        (10.67, SIMD3(0.4557, -0.0093, -0.5145), 0.0078),
        (10.83, SIMD3(0.4517, -0.0087, -0.5143), 0.0075),
        (11.00, SIMD3(0.4467, -0.0060, -0.5083), 0.0074),
        (11.25, SIMD3(0.4426, -0.0045, -0.5053), 0.0071),
        (11.50, SIMD3(0.4369, -0.0027, -0.5018), 0.0066),
        (11.75, SIMD3(0.4356, -0.0018, -0.5010), 0.0065),
        (12.00, SIMD3(0.4329, -0.0007, -0.4987), 0.0063),
        (12.20, SIMD3(0.4315, 0.0013, -0.4951), 0.0065),
        (12.40, SIMD3(0.4323, 0.0042, -0.4896), 0.0070),
        (12.60, SIMD3(0.4359, 0.0025, -0.4930), 0.0071),
        (12.80, SIMD3(0.4361, 0.0022, -0.4936), 0.0069),
        (13.00, SIMD3(0.4488, 0.0018, -0.4933), 0.0084),
        (13.14, SIMD3(0.4551, 0.0027, -0.4918), 0.0092),
        (13.29, SIMD3(0.4679, -0.0052, -0.5060), 0.0088),
        (13.43, SIMD3(0.4613, -0.0019, -0.5001), 0.0083),
        (13.57, SIMD3(0.4569, -0.0000, -0.4961), 0.0081),
        (13.71, SIMD3(0.4698, -0.0080, -0.5100), 0.0076),
        (13.86, SIMD3(0.4643, -0.0042, -0.5038), 0.0073),
        (14.00, SIMD3(0.4584, -0.0008, -0.4977), 0.0070),
        (14.11, SIMD3(0.4711, -0.0081, -0.5115), 0.0066),
        (14.22, SIMD3(0.4637, -0.0046, -0.5046), 0.0063),
        (14.33, SIMD3(0.4589, -0.0022, -0.5000), 0.0059),
        (14.44, SIMD3(0.4613, -0.0031, -0.5021), 0.0060),
        (14.56, SIMD3(0.4624, -0.0027, -0.5023), 0.0059),
        (14.67, SIMD3(0.4767, -0.0078, -0.5156), 0.0057),
        (14.78, SIMD3(0.4670, -0.0045, -0.5082), 0.0054),
        (14.89, SIMD3(0.4701, -0.0063, -0.5104), 0.0054),
        (15.00, SIMD3(0.4738, -0.0072, -0.5125), 0.0056),
        (15.20, SIMD3(0.4693, -0.0046, -0.5085), 0.0054),
        (15.40, SIMD3(0.4664, -0.0048, -0.5080), 0.0053),
        (15.60, SIMD3(0.4675, -0.0053, -0.5088), 0.0053),
        (15.80, SIMD3(0.4677, -0.0056, -0.5094), 0.0052),
        (16.00, SIMD3(0.4727, -0.0077, -0.5141), 0.0053),
        (16.25, SIMD3(0.4744, -0.0082, -0.5164), 0.0053),
        (16.50, SIMD3(0.4727, -0.0078, -0.5148), 0.0053),
        (16.75, SIMD3(0.4719, -0.0081, -0.5155), 0.0053),
        (17.00, SIMD3(0.4742, -0.0080, -0.5167), 0.0054),
        (17.25, SIMD3(0.4752, -0.0077, -0.5176), 0.0054),
        (17.50, SIMD3(0.4755, -0.0073, -0.5174), 0.0054),
        (17.75, SIMD3(0.4768, -0.0076, -0.5190), 0.0055),
        (18.00, SIMD3(0.4784, -0.0088, -0.5209), 0.0055),
        (18.25, SIMD3(0.4782, -0.0092, -0.5212), 0.0055),
        (18.50, SIMD3(0.4774, -0.0089, -0.5208), 0.0055),
        (18.75, SIMD3(0.4771, -0.0083, -0.5209), 0.0055),
        (19.00, SIMD3(0.4763, -0.0084, -0.5199), 0.0056),
        (19.25, SIMD3(0.4760, -0.0079, -0.5192), 0.0056),
        (19.50, SIMD3(0.4762, -0.0075, -0.5194), 0.0056),
        (19.75, SIMD3(0.4763, -0.0073, -0.5189), 0.0056),
        (20.00, SIMD3(0.4756, -0.0070, -0.5186), 0.0056),
        (20.25, SIMD3(0.4753, -0.0071, -0.5184), 0.0056),
        (20.50, SIMD3(0.4761, -0.0072, -0.5190), 0.0057),
        (20.75, SIMD3(0.4759, -0.0073, -0.5192), 0.0057)
    ]

    @Test func aGlossyDisplayReadDeeperFromFurtherAwayStaysWhereItIs() {
        var byPosition = TrackGate(), byImage = TrackGate()
        var before: [TrackGate.Verdict] = [], now: [TrackGate.Verdict] = []
        for (t, p, area) in Self.display {
            before.append(byPosition.judge(time: t, position: p, area: area))
            now.append(byImage.judge(time: t, position: p, area: area, covered: true))
        }
        // As on the phone: masks refused, then a move.
        #expect(before.contains { if case .reject = $0 { return true } else { return false } })
        #expect(before.contains(.moved))
        #expect(now.allSatisfy { $0 == .accept })
    }

    @Test func aLookAlikeIsStillRefusedWhenItDoesNotCoverWhereTheObjectLay() {
        var gate = TrackGate()
        var t = Self.still(&gate, for: 1)
        for k in 0..<4 {
            let v = gate.judge(time: t, position: Self.key + SIMD3(0.04 + Float(k % 2) * 0.001, 0, 0), covered: false)
            #expect(v != .moved && v != .accept)
            t += 0.1
        }
    }

    @Test func coveringWhereTheObjectLayDoesNotExcuseAnyDepth() {
        var gate = TrackGate()
        let t = Self.still(&gate, for: 1)
        // On the same line of sight but 25 cm further: something else behind it.
        if case .reject = gate.judge(time: t, position: Self.key + SIMD3(0, 0, -0.25), covered: true) {} else { Issue.record("taken") }
    }

    @Test func aMaskCoversAPointOnItOrWithinACellOfIt() {
        var low = [UInt8](repeating: 0, count: 256 * 256)
        for y in 100..<120 { for x in 50..<90 { low[y * 256 + x] = 1 } }
        let f = EdgeTAM.Frame(objectScore: 5, iou: 0.9, box: nil, centroid: nil, area: 0.01, lowRes: low, crop: [], cropRect: .zero,
                              outline: [], encodeMs: 0, decodeMs: 0)
        #expect(f.covers(u: 70.5 / 256, v: 110.5 / 256))
        #expect(f.covers(u: 90.5 / 256, v: 110.5 / 256))
        #expect(!f.covers(u: 92.5 / 256, v: 110.5 / 256))
        #expect(!f.covers(u: 0.9, v: 0.1))
    }

    @Test func anImpossibleLeapWhileMovingIsAGlitch() {
        var gate = TrackGate()
        var t = 0.0
        for k in 0..<5 {
            #expect(gate.judge(time: t, position: Self.key + SIMD3(Float(k) * 0.03, 0, 0)) == .accept)
            t += 0.1
        }
        // 60 cm in a tenth of a second.
        if case .reject = gate.judge(time: t, position: Self.key + SIMD3(0.72, 0, 0)) {} else { Issue.record("taken") }
    }
}
