import Foundation

/// A raw `[[name key=value …]]` tag as it appeared in the model's text.
public struct CueTag: Equatable, Sendable {
    public var name: String
    public var attributes: [String: String]
    public var raw: String

    /// Parses the inside of a tag (without the brackets). Values may be quoted: `reason="hot surface"`.
    public static func parse(_ body: String) -> CueTag? {
        let raw = "[[\(body)]]"
        // Models sometimes write lists as "m=3, 4": join them before splitting attributes.
        let normalized = body.replacingOccurrences(of: #",\s+(?=\d)"#, with: ",", options: .regularExpression)
        var scanner = Substring(normalized.trimmingCharacters(in: .whitespacesAndNewlines))
        let nameEnd = scanner.firstIndex(where: { $0 == " " || $0 == ":" }) ?? scanner.endIndex
        let name = scanner[..<nameEnd].lowercased()
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0 == "_" }) else { return nil }
        scanner = scanner[nameEnd...]
        var attributes: [String: String] = [:]

        // Tolerate the compact spike form `[[outline:13]]` / `[[move:13:up]]`.
        if scanner.first == ":" {
            let parts = scanner.dropFirst().split(separator: ":").map(String.init)
            if let m = parts.first { attributes["m"] = m }
            if parts.count > 1 { attributes["dir"] = parts[1] }
            return CueTag(name: name, attributes: attributes, raw: raw)
        }

        while true {
            scanner = scanner.drop(while: { $0 == " " || $0 == "\t" })
            guard !scanner.isEmpty else { break }
            guard let eq = scanner.firstIndex(of: "=") else { return nil }
            let key = scanner[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, !key.contains(" ") else { return nil }
            scanner = scanner[scanner.index(after: eq)...]
            let value: Substring
            if let quote = scanner.first, quote == "\"" || quote == "“" || quote == "'" {
                let closing: Character = quote == "“" ? "”" : quote
                let rest = scanner.dropFirst()
                guard let end = rest.firstIndex(of: closing) else { return nil }
                value = rest[..<end]
                scanner = rest[rest.index(after: end)...]
            } else {
                let end = scanner.firstIndex(of: " ") ?? scanner.endIndex
                value = scanner[..<end]
                scanner = scanner[end...]
            }
            attributes[key] = String(value)
        }
        return CueTag(name: name, attributes: attributes, raw: raw)
    }
}

public enum MoveDirection: String, Sendable, CaseIterable { case up, down, left, right, `in`, out }
public enum RotationDirection: String, Sendable, CaseIterable { case cw, ccw }
public enum RotationAmount: String, Sendable, CaseIterable { case quarter, half, full }

/// What Pip means by a tag. The model chooses the meaning; the renderer chooses the visuals.
public enum Cue: Equatable, Sendable {
    // Drawn on the scene.
    case outline(mark: Int)
    case ring(mark: Int, label: String?)
    case candidates(marks: [Int])
    case move(mark: Int, direction: MoveDirection)
    case rotate(mark: Int, direction: RotationDirection, amount: RotationAmount)
    case place(mark: Int)
    case sequence(marks: [Int])
    case danger(mark: Int?, reason: String)
    case offscreen(mark: Int)
    case verified(mark: Int)
    case clear
    // Side channel for the runtime; never drawn.
    case state([String: String])
    case locate(x: Int, y: Int, label: String?)
    case needView(reason: String, hint: String?)
    /// A durable fact to remember for the rest of the session, e.g. computer = Mac.
    case remember(key: String, value: String, source: String)

    public var isDrawn: Bool {
        switch self {
        case .state, .locate, .needView, .remember: return false
        default: return true
        }
    }

    /// Every mark the cue refers to.
    public var marks: [Int] {
        switch self {
        case .outline(let m), .ring(let m, _), .move(let m, _), .rotate(let m, _, _), .place(let m), .offscreen(let m), .verified(let m):
            return [m]
        case .candidates(let ms), .sequence(let ms):
            return ms
        case .danger(let m, _):
            return m.map { [$0] } ?? []
        case .clear, .state, .locate, .needView, .remember:
            return []
        }
    }

    /// The same cue with its mark numbers changed, e.g. to keep marks of different looks apart.
    public func mappingMarks(_ f: (Int) -> Int) -> Cue {
        switch self {
        case .outline(let m): return .outline(mark: f(m))
        case .ring(let m, let l): return .ring(mark: f(m), label: l)
        case .candidates(let ms): return .candidates(marks: ms.map(f))
        case .move(let m, let d): return .move(mark: f(m), direction: d)
        case .rotate(let m, let d, let a): return .rotate(mark: f(m), direction: d, amount: a)
        case .place(let m): return .place(mark: f(m))
        case .sequence(let ms): return .sequence(marks: ms.map(f))
        case .danger(let m, let r): return .danger(mark: m.map(f), reason: r)
        case .offscreen(let m): return .offscreen(mark: f(m))
        case .verified(let m): return .verified(mark: f(m))
        case .clear, .state, .locate, .needView, .remember: return self
        }
    }
}

public struct CueError: Error, Equatable, Sendable, CustomStringConvertible {
    public var raw: String
    public var reason: String
    public var description: String { "\(raw): \(reason)" }
}

extension Cue {
    public static func from(_ tag: CueTag) -> Result<Cue, CueError> {
        func fail(_ reason: String) -> Result<Cue, CueError> { .failure(CueError(raw: tag.raw, reason: reason)) }
        func mark(_ key: String = "m") -> Int? { tag.attributes[key].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        func marks() -> [Int]? {
            guard let v = tag.attributes["m"] else { return nil }
            let list = v.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return list.isEmpty ? nil : list
        }
        let a = tag.attributes

        switch tag.name {
        case "outline":
            guard let m = mark() else { return fail("needs m") }
            return .success(.outline(mark: m))
        case "ring":
            guard let m = mark() else { return fail("needs m") }
            return .success(.ring(mark: m, label: a["label"]))
        case "candidates":
            guard let ms = marks(), ms.count >= 1 else { return fail("needs m=a,b") }
            return .success(.candidates(marks: ms))
        case "move", "arrow", "push", "pull":
            guard let m = mark() else { return fail("needs m") }
            guard let d = a["dir"].flatMap({ MoveDirection(rawValue: $0.lowercased()) }) else { return fail("dir must be up|down|left|right|in|out") }
            return .success(.move(mark: m, direction: d))
        case "rotate", "turn":
            guard let m = mark() else { return fail("needs m") }
            guard let d = a["dir"].flatMap({ RotationDirection(rawValue: $0.lowercased()) }) else { return fail("dir must be cw|ccw") }
            let amount = a["amount"].flatMap { RotationAmount(rawValue: $0.lowercased()) } ?? .quarter
            return .success(.rotate(mark: m, direction: d, amount: amount))
        case "place":
            guard let m = mark() else { return fail("needs m") }
            return .success(.place(mark: m))
        case "seq", "sequence":
            guard let ms = marks(), ms.count >= 2 else { return fail("needs m=a,b,…") }
            return .success(.sequence(marks: ms))
        case "danger":
            return .success(.danger(mark: mark(), reason: a["reason"] ?? "hazard"))
        case "offscreen":
            guard let m = mark() else { return fail("needs m") }
            return .success(.offscreen(mark: m))
        case "verified":
            guard let m = mark() else { return fail("needs m") }
            return .success(.verified(mark: m))
        case "clear":
            return .success(.clear)
        case "state":
            return .success(.state(a))
        case "locate":
            guard let x = mark("x"), let y = mark("y"), (0...1000).contains(x), (0...1000).contains(y) else {
                return fail("needs x and y on the 0–1000 grid")
            }
            return .success(.locate(x: x, y: y, label: a["label"]))
        case "need_view", "needview":
            return .success(.needView(reason: a["reason"] ?? "unclear", hint: a["hint"]))
        case "remember":
            guard let key = a["key"]?.trimmingCharacters(in: .whitespaces), !key.isEmpty,
                  let value = a["value"]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return fail("needs key and value") }
            return .success(.remember(key: key.lowercased(), value: value, source: (a["from"] ?? a["source"] ?? "said").lowercased()))
        default:
            return fail("unknown cue")
        }
    }
}
