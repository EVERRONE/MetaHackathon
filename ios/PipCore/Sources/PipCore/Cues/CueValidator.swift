import Foundation

/// What the runtime knows about a numbered mark from the current look.
public struct MarkInfo: Equatable, Sendable {
    public var id: Int
    public var confidence: Double
    public var label: String?

    public init(id: Int, confidence: Double, label: String? = nil) {
        self.id = id
        self.confidence = confidence
        self.label = label
    }
}

/// Checks every cue before anything is drawn. A wrong cue hurts more than no cue.
public struct CueValidator: Sendable {
    public enum Decision: Equatable, Sendable {
        case accept(Cue)
        case downgrade(Cue, reason: String)
        case reject(reason: String)

        public var cue: Cue? {
            switch self {
            case .accept(let c), .downgrade(let c, _): return c
            case .reject: return nil
            }
        }
    }

    /// Below this SAM confidence a solid outline or an action arrow becomes a candidate outline.
    public var minConfidence: Double

    public init(minConfidence: Double = 0.45) {
        self.minConfidence = minConfidence
    }

    public func validate(_ cue: Cue, marks: [Int: MarkInfo], hasEvidence: (Int) -> Bool) -> Decision {
        switch cue {
        case .clear, .state, .locate, .needView, .remember, .task, .readPages, .find, .list:
            return .accept(cue)

        case .danger(let m, let reason):
            // Danger always wins; an unknown mark still shows as a general warning.
            if let m, marks[m] == nil {
                return .downgrade(.danger(mark: nil, reason: reason), reason: "unknown mark \(m); shown as a general warning")
            }
            return .accept(cue)

        case .verified(let m):
            guard marks[m] != nil else { return .reject(reason: "unknown mark \(m)") }
            guard hasEvidence(m) else { return .reject(reason: "no camera evidence for mark \(m)") }
            return .accept(cue)

        case .candidates(let ms), .sequence(let ms):
            let known = ms.filter { marks[$0] != nil }
            guard !known.isEmpty else { return .reject(reason: "unknown marks \(ms)") }
            let rebuilt: Cue = { if case .candidates = cue { return .candidates(marks: known) } else { return .sequence(marks: known) } }()
            if case .sequence = rebuilt, known.count < 2 { return .downgrade(.outline(mark: known[0]), reason: "sequence reduced to one known mark") }
            return known.count == ms.count ? .accept(rebuilt) : .downgrade(rebuilt, reason: "dropped unknown marks")

        case .offscreen(let m), .landmark(let m, _):
            return marks[m] == nil ? .reject(reason: "unknown mark \(m)") : .accept(cue)

        case .outline(let m), .ring(let m, _), .move(let m, _), .rotate(let m, _, _), .place(let m):
            guard let info = marks[m] else { return .reject(reason: "unknown mark \(m)") }
            if info.confidence < minConfidence {
                return .downgrade(.candidates(marks: [m]), reason: String(format: "mark %d confidence %.2f below %.2f", m, info.confidence, minConfidence))
            }
            return .accept(cue)
        }
    }
}

/// What is on screen, with the lifetimes from the visual rules.
public struct AnnotationBoard: Sendable {
    public enum Lifetime: Equatable, Sendable {
        /// "This one": fades on its own.
        case transient(until: TimeInterval)
        /// The current action: stays until the step is verified or cleared.
        case untilVerified
        /// A hazard: stays until the runtime resolves it.
        case untilResolved
    }

    public struct Annotation: Equatable, Sendable {
        public var cue: Cue
        public var shownAt: TimeInterval
        public var lifetime: Lifetime
    }

    public static let maxMarks = 3
    public static let transientSeconds: TimeInterval = 6
    public static let candidateSeconds: TimeInterval = 8

    public private(set) var annotations: [Annotation] = []

    public init() {}

    public mutating func show(_ cue: Cue, at now: TimeInterval) {
        switch cue {
        case .clear:
            annotations.removeAll { $0.lifetime != .untilResolved }
            return
        case .state, .locate, .needView, .remember, .task, .readPages, .find, .list:
            return
        case .verified(let m):
            // A verified mark ends the action cues on it.
            annotations.removeAll { $0.lifetime == .untilVerified && $0.cue.marks.contains(m) }
        default:
            break
        }

        // Pointing stays on the object while the user works, also when they look away and back;
        // it is replaced by the next answer's cues. A question between look-alikes and a
        // confirmation fade on their own.
        let lifetime: Lifetime
        switch cue {
        case .danger: lifetime = .untilResolved
        case .candidates: lifetime = .transient(until: now + Self.candidateSeconds)
        case .verified, .landmark: lifetime = .transient(until: now + Self.transientSeconds)
        default: lifetime = .untilVerified
        }

        // A new cue on the same marks replaces the old one of the same family.
        annotations.removeAll { $0.lifetime != .untilResolved && $0.cue.marks == cue.marks && !cue.marks.isEmpty && Self.sameFamily($0.cue, cue) }
        annotations.append(Annotation(cue: cue, shownAt: now, lifetime: lifetime))
        enforceMarkLimit()
    }

    public mutating func tick(_ now: TimeInterval) {
        annotations.removeAll {
            if case .transient(let until) = $0.lifetime { return now >= until }
            return false
        }
    }

    public mutating func resolveDanger() {
        annotations.removeAll { $0.lifetime == .untilResolved }
    }

    public var activeMarks: Set<Int> { Set(annotations.flatMap { $0.cue.marks }) }

    private static func sameFamily(_ a: Cue, _ b: Cue) -> Bool {
        switch (a, b) {
        case (.outline, .outline), (.ring, .ring), (.candidates, .candidates), (.offscreen, .offscreen), (.verified, .verified), (.landmark, .landmark):
            return true
        case (.move, .move), (.rotate, .rotate), (.place, .place), (.sequence, .sequence),
             (.move, .rotate), (.rotate, .move):
            return true
        default:
            return false
        }
    }

    /// At most three marks on screen: drop the oldest non-danger annotations first, but never the
    /// one just added.
    private mutating func enforceMarkLimit() {
        // The newest stays last, because only older ones are removed.
        while activeMarks.count > Self.maxMarks,
              let oldest = annotations.indices.first(where: { $0 != annotations.count - 1 && annotations[$0].lifetime != .untilResolved }) {
            annotations.remove(at: oldest)
        }
    }
}
