import Foundation

/// A guided task: what to do, on which objects, and how each step is checked.
/// Compiled from the user's goal and an optional source (photos, PDF, text), or drafted without one.
public struct Procedure: Codable, Equatable, Sendable {
    public enum SourceKind: String, Codable, Sendable { case images, pdf, text, none }

    public struct Source: Codable, Equatable, Sendable {
        public var kind: SourceKind
        /// What the source is, e.g. "manual page 12" or the user's own words.
        public var reference: String?

        /// Only a procedure taken from a source the user gave counts as verified.
        public var verified: Bool { kind != .none }

        public init(kind: SourceKind, reference: String? = nil) {
            self.kind = kind
            self.reference = reference
        }
    }

    public struct ObjectSpec: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// A generic noun SAM understands: "knob", "breaker", "filter".
        public var phrase: String
        /// Text printed on it, if any.
        public var text: [String]

        public init(id: String, name: String, phrase: String, text: [String] = []) {
            self.id = id
            self.name = name
            self.phrase = phrase
            self.text = text
        }
    }

    public struct Check: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// The result is visible: Pip looks and checks it.
            case camera
            /// The result is not visible but the user can tell: Pip asks.
            case user
            /// Nobody can check it here (a torque, a voltage): Pip says so.
            case none
        }

        public var kind: Kind
        /// The result that shows the step is done: "the lever points up", "the light is green".
        public var expected: String

        public init(kind: Kind, expected: String) {
            self.kind = kind
            self.expected = expected
        }
    }

    public struct Step: Codable, Equatable, Sendable {
        public var id: String
        public var instruction: String
        public var why: String?
        /// Ids of the objects the step acts on.
        public var targets: [String]
        public var check: Check
        public var cautions: [String]
        /// A condition the user must confirm before this step starts, e.g. "the power is off".
        public var gate: String?
        /// Where in the source this step comes from.
        public var sourceRef: String?

        public init(id: String, instruction: String, why: String? = nil, targets: [String] = [], check: Check,
                    cautions: [String] = [], gate: String? = nil, sourceRef: String? = nil) {
            self.id = id
            self.instruction = instruction
            self.why = why
            self.targets = targets
            self.check = check
            self.cautions = cautions
            self.gate = gate
            self.sourceRef = sourceRef
        }
    }

    public var title: String
    public var goal: String
    public var source: Source
    public var objects: [ObjectSpec]
    public var steps: [Step]
    public var cautions: [String]

    public init(title: String, goal: String, source: Source, objects: [ObjectSpec], steps: [Step], cautions: [String] = []) {
        self.title = title
        self.goal = goal
        self.source = source
        self.objects = objects
        self.steps = steps
        self.cautions = cautions
    }

    public func object(_ id: String) -> ObjectSpec? { objects.first { $0.id == id } }

    /// Problems that make a procedure unusable: no steps, unknown object ids, duplicate step ids.
    public func problems() -> [String] {
        var out: [String] = []
        if steps.isEmpty { out.append("no steps") }
        let ids = Set(objects.map(\.id))
        for s in steps {
            for t in s.targets where !ids.contains(t) { out.append("step \(s.id) targets unknown object \(t)") }
            if s.instruction.trimmingCharacters(in: .whitespaces).isEmpty { out.append("step \(s.id) has no instruction") }
        }
        if Set(steps.map(\.id)).count != steps.count { out.append("duplicate step ids") }
        return out
    }
}
