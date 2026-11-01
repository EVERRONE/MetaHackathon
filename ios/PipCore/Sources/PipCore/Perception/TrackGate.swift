import simd

/// Keeps a followed object from jumping to a look-alike.
///
/// EdgeTAM can lose an object in a fast camera move (motion blur) and take up a similar one nearby;
/// its memory then follows the wrong one. On 1 Nov the Windows key's outline went to the key left of
/// it, then two keys further, for about ten seconds. An object that lay still does not jump: a
/// mask that puts it more than `jump` from where it lay is not taken (and EdgeTAM is made to forget
/// that frame), unless the new place holds for `confirm` masks in a row and no image lock says the
/// object is still where it was: then it was moved.
public struct TrackGate: Sendable {
    /// Further than this from where the object lay still is a jump (a key is 1.5–2 cm wide).
    public var jump: Float = 0.03
    /// Still: the last `stillFor` seconds of accepted positions within `stillRadius` of their mean
    /// (a still object's centre moves 1–2 mm per mask, up to a centimetre with depth noise).
    public var stillFor: Double = 0.5
    public var stillRadius: Float = 0.015
    /// Masks in a row at one new place before it counts as moved.
    public var confirm = 5
    /// Faster than this between two masks is a glitch, also for an object in the hand.
    public var maxSpeed: Float = 2.5

    public enum Verdict: Equatable, Sendable {
        case accept
        /// Not taken; the distance from where the object lay still (or from its last place).
        case reject(Float)
        /// Taken: the object was moved to a new place, confirmed by several masks.
        case moved
    }

    private var accepted: [(t: Double, p: SIMD3<Float>)] = []
    private var pending: [(t: Double, p: SIMD3<Float>)] = []

    public init() {}

    /// Where the object has lain still, if it has.
    public var anchor: SIMD3<Float>? {
        guard let last = accepted.last else { return nil }
        let window = accepted.filter { last.t - $0.t <= stillFor }
        guard let first = window.first, last.t - first.t >= stillFor * 0.8, window.count >= 3 else { return nil }
        let mean = window.reduce(SIMD3<Float>(), { $0 + $1.p }) / Float(window.count)
        return window.allSatisfy { simd_distance($0.p, mean) <= stillRadius } ? mean : nil
    }

    /// Masks disagree with where the object lay: better to show nothing than the wrong place.
    public var uncertain: Bool { pending.count >= 2 }

    /// `lockHeld`: an image lock saw the object's face recently, where it lay. `recentlyLost`:
    /// EdgeTAM did not see the object a moment ago (a fast turn): then a new place needs twice the
    /// confirmation, and a path away from where it lay does not count (on 1 Nov the wrong mask
    /// slid steadily along the neighbouring keys).
    public mutating func judge(time t: Double, position p: SIMD3<Float>, lockHeld: Bool, recentlyLost: Bool = false) -> Verdict {
        if let a = anchor {
            let d = simd_distance(p, a)
            if d <= jump {
                pending = []
                record(t, p)
                return .accept
            }
            let needed = recentlyLost ? 2 * confirm : confirm
            pending.append((t, p))
            if pending.count > needed { pending.removeFirst(pending.count - needed) }
            if !lockHeld, pending.count >= needed {
                let mean = pending.reduce(SIMD3<Float>(), { $0 + $1.p }) / Float(pending.count)
                if pending.allSatisfy({ simd_distance($0.p, mean) <= jump }) {
                    accepted = pending
                    pending = []
                    return .moved
                }
            }
            // Picked up faster than the masks: a steady path away from where it lay, unlike a jump
            // to a look-alike, which stays put. Followed from the third mask on.
            if !lockHeld, !recentlyLost, Self.leaving(a, pending.suffix(3), maxSpeed: maxSpeed) {
                accepted = Array(pending.suffix(3))
                pending = []
                return .moved
            }
            return .reject(d)
        }
        // Moving, or not lain still long enough: only an impossible speed is refused.
        if let last = accepted.last, t > last.t {
            let d = simd_distance(p, last.p)
            if d / Float(max(t - last.t, 0.05)) > maxSpeed {
                pending.append((t, p))
                if pending.count > confirm { pending.removeFirst(pending.count - confirm) }
                return .reject(d)
            }
        }
        pending = []
        record(t, p)
        return .accept
    }

    /// At least three masks on a steady path that starts near `from`: each step at least 5 mm (more
    /// than a still object's noise), at a possible speed, all in about the same direction.
    static func leaving(_ from: SIMD3<Float>, _ path: ArraySlice<(t: Double, p: SIMD3<Float>)>, maxSpeed: Float) -> Bool {
        let pts = Array(path)
        guard pts.count >= 3, simd_distance(pts[0].p, from) <= 0.08 else { return false }
        var steps: [SIMD3<Float>] = [pts[0].p - from]
        for i in 1..<pts.count {
            let step = pts[i].p - pts[i - 1].p
            let dt = Float(max(pts[i].t - pts[i - 1].t, 0.05))
            guard simd_length(step) >= 0.005, simd_length(step) / dt <= maxSpeed else { return false }
            steps.append(step)
        }
        for i in 1..<steps.count where simd_dot(simd_normalize(steps[i]), simd_normalize(steps[i - 1])) < 0.5 { return false }
        return true
    }

    public mutating func reset() {
        accepted = []
        pending = []
    }

    private mutating func record(_ t: Double, _ p: SIMD3<Float>) {
        accepted.append((t, p))
        accepted.removeAll { t - $0.t > 2 }
    }
}
