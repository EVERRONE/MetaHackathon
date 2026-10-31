import CoreGraphics
import PipCore
import QuartzCore
import simd

/// What Pip knows about one pointed-at object over time, the way a visual positioning system
/// keeps content in "map space": every measurement is a ray from where the phone was, the rays
/// are fused into one position that gets firmer with every view, and Pip measures again at the
/// moments drift or movement show up: when the object comes back into view, when the phone has
/// moved far enough to triangulate, and regularly during a task.
struct ObjectTrack {
    enum Reason: String {
        /// The object came back into view, or tracking came back: Pip may have drifted meanwhile.
        case reentry
        /// The phone moved far enough for a new angle on the object.
        case newView
        /// A regular check during a task: has the object moved?
        case check

        var priority: Int {
            switch self {
            case .reentry: return 3
            case .newView: return 2
            case .check: return 1
            }
        }
    }

    /// The outcome of one measurement, for the trace and the tracking log.
    struct Update {
        var position: simd_float3?
        var views: Int
        /// Earlier views were dropped: the object moved, or Pip had drifted.
        var reset: Bool
        /// After a re-entry: how far Pip had drifted (the same for everything in the room).
        var offset: simd_float3?
        /// How far the outline was from the object in this snapshot, before the correction.
        var pixelError: Double?
        var method = ""
    }

    private(set) var observations: [RayFusion.Observation]
    /// What the model asked to point at, to find the object again after drift.
    let spec: TargetSpec?
    var box: CGRect
    let created: TimeInterval
    private(set) var lastMeasured: TimeInterval
    private var lastTried: TimeInterval = 0
    private var failures = 0
    private var outOfViewSince: TimeInterval?
    /// Measure before trusting it again: it came back into view, or tracking came back.
    var needsCheck = false
    /// Out of view right now.
    var isAway: Bool { outOfViewSince != nil }

    static let maxViews = 8
    /// At most one measurement per object this often.
    static let minInterval: TimeInterval = 2
    /// Out of view this long, and the object is checked when it comes back.
    static let awayBeforeCheck: TimeInterval = 4
    /// A new view counts once the phone moved this far from every earlier view, or looks at the
    /// object from this many degrees further round.
    static let newViewBaseline: Float = 0.08
    static let newViewAngle: Float = 8
    static let checkInterval: TimeInterval = 8
    /// Outside a task, new views are measured for this long after Pip pointed.
    static let followFor: TimeInterval = 5 * 60
    static let maxFailures = 3

    init(observation: RayFusion.Observation, spec: TargetSpec?, box: CGRect, imageSize: CGSize) {
        observations = [observation]
        self.spec = spec
        self.box = box
        created = observation.time
        lastMeasured = observation.time
    }

    /// Notes whether the object is on screen. Returns true when something changed.
    mutating func noteVisible(_ inView: Bool, now: TimeInterval) -> Bool {
        if inView {
            guard let since = outOfViewSince else { return false }
            if now - since > Self.awayBeforeCheck {
                needsCheck = true
                failures = 0
            }
            outOfViewSince = nil
            return true
        }
        if outOfViewSince == nil {
            outOfViewSince = now
            return true
        }
        return false
    }

    /// Why to measure the object now, or nil.
    func reason(now: TimeInterval, camera: simd_float3, centre: simd_float3, taskActive: Bool) -> Reason? {
        guard now - max(lastMeasured, lastTried) >= Self.minInterval else { return nil }
        if needsCheck { return failures < Self.maxFailures ? .reentry : nil }
        if taskActive || now - created < Self.followFor {
            let direction = simd_normalize(centre - camera)
            let nearest = observations.map { simd_distance(camera, $0.origin) }.min() ?? 0
            let closestAngle = observations.map { acos(max(-1, min(1, simd_dot(direction, $0.direction)))) * 180 / .pi }.min() ?? 0
            if nearest >= Self.newViewBaseline || closestAngle >= Self.newViewAngle { return .newView }
        }
        if taskActive, now - lastMeasured >= Self.checkInterval { return .check }
        return nil
    }

    /// Adds a measurement. `correction` is how ARKit moved the object's anchor since the earlier
    /// views were taken; `predicted` is where the outline was drawn.
    mutating func add(_ obs: RayFusion.Observation, correction: simd_float4x4, reason: Reason, predicted: simd_float3) -> Update {
        lastMeasured = obs.time
        failures = 0
        align(correction)
        let prior = RayFusion.fuse(observations) ?? predicted
        var reset = false
        var offset: simd_float3?
        let newPoint = obs.point ?? (obs.origin + obs.direction * simd_dot(prior - obs.origin, obs.direction))
        if reason == .reentry {
            // Coming back: the earlier views carry the drift. This view is the truth now, and the
            // difference is the drift every other object in the room has too.
            offset = newPoint - prior
            observations = [obs]
            reset = true
            needsCheck = false
        } else if RayFusion.lateralError(prior, obs) > max(0.04, 8 * obs.lateralSigma) {
            // Far from every earlier view: the object was moved. Start again from here.
            observations = [obs]
            reset = true
        } else {
            observations.append(obs)
            if observations.count > Self.maxViews { observations.removeFirst(observations.count - Self.maxViews) }
        }
        return Update(position: RayFusion.fuse(observations), views: observations.count, reset: reset, offset: offset)
    }

    mutating func failed(now: TimeInterval) {
        lastTried = now
        failures += 1
        if failures >= Self.maxFailures { needsCheck = false }
    }

    /// Brings the earlier views along with ARKit's correction of the object's anchor.
    mutating func align(_ correction: simd_float4x4) {
        observations = observations.map { Self.moved($0, by: correction) }
    }

    /// The same drift for every object: its views move along.
    mutating func shifted(by offset: simd_float3) {
        observations = observations.map {
            var o = $0
            o.origin += offset
            return o
        }
    }

    private static func moved(_ o: RayFusion.Observation, by t: simd_float4x4) -> RayFusion.Observation {
        guard t != matrix_identity_float4x4 else { return o }
        var m = o
        let p = t * simd_float4(o.origin, 1)
        m.origin = simd_float3(p.x, p.y, p.z)
        let d = t * simd_float4(o.direction, 0)
        m.direction = simd_normalize(simd_float3(d.x, d.y, d.z))
        return m
    }
}
