import ARKit
import Foundation

/// Watches ARKit recognise a saved room at start, and how well the room is being mapped, without
/// the user doing anything: it logs each attempt (which piece, how long it took, in which light) to
/// Documents/relocalise.log, shows a line on screen while it matters, and says when the user should
/// move more slowly or look around for the mapping to work (see GuideModel+Memory).
final class Relocalisation {
    enum Hint { case moveSlower, lookAround, moreFeatures }

    private var attemptStarted = CACurrentMediaTime()
    private var attempt: String?
    private(set) var recognisedAfter: TimeInterval?
    private var newRoomAt: TimeInterval?
    private(set) var mapping: ARFrame.WorldMappingStatus = .notAvailable
    private var lastState = ""
    private var lastMapping: ARFrame.WorldMappingStatus?
    private var lastPeriodic: TimeInterval = 0
    private var lastStatus: TimeInterval = 0
    private var savedAt: TimeInterval?
    private var startLight: CGFloat?
    /// Since when ARKit has said the phone moves too fast, or sees too little.
    private var fastSince: TimeInterval?
    private var bareSince: TimeInterval?
    var onStatus: ((String) -> Void)?
    var onHint: ((Hint) -> Void)?

    /// ARKit tries to recognise `piece` (its first four characters for the log), or none.
    func trying(_ piece: String?, detail: String) {
        attemptStarted = CACurrentMediaTime()
        attempt = piece
        recognisedAfter = nil
        newRoomAt = piece == nil ? attemptStarted : nil
        startLight = nil
        Self.log(piece.map { "trying piece \($0) (\(detail))" } ?? "no saved room to recognise: mapping a new one (\(detail))")
    }

    /// The tried piece was not recognised in time.
    func gaveUp() {
        Self.log(String(format: "piece %@ not recognised after %.1f s", attempt ?? "?", CACurrentMediaTime() - attemptStarted))
    }

    func saved(_ ok: Bool, detail: String) {
        if ok { savedAt = CACurrentMediaTime() }
        Self.log((ok ? "map saved: " : "map not saved: ") + detail)
    }

    /// Every camera frame.
    func frame(_ frame: ARFrame, awaitingRecognition: Bool) {
        let now = CACurrentMediaTime()
        let t = now - attemptStarted
        let light = frame.lightEstimate?.ambientIntensity ?? -1
        if startLight == nil, light >= 0 { startLight = light }
        mapping = frame.worldMappingStatus
        let state = Self.describe(frame.camera.trackingState)
        if state != lastState || mapping != lastMapping {
            lastState = state
            lastMapping = mapping
            Self.log(String(format: "%.1f s: %@, map %@, light %.0f lm, %d features", t, state, Self.describe(mapping), light,
                            frame.rawFeaturePoints?.points.count ?? 0))
        }
        if attempt != nil, recognisedAfter == nil, !awaitingRecognition, case .normal = frame.camera.trackingState {
            recognisedAfter = t
            let p = frame.camera.transform.columns.3
            Self.log(String(format: "RECOGNISED piece %@ after %.1f s (light at start %.0f lm, now %.0f lm), at %.2f, %.2f, %.2f",
                            attempt ?? "?", t, startLight ?? -1, light, p.x, p.y, p.z))
        }
        if awaitingRecognition, t - lastPeriodic >= 5 {
            lastPeriodic = t
            Self.log(String(format: "%.0f s: still recognising (light %.0f lm, %d features)", t, light, frame.rawFeaturePoints?.points.count ?? 0))
        }
        hints(frame.camera.trackingState, awaitingRecognition: awaitingRecognition, t: t, now: now)
        if now - lastStatus >= 0.5 {
            lastStatus = now
            onStatus?(status(t, awaitingRecognition: awaitingRecognition, now: now))
        }
    }

    private func hints(_ state: ARCamera.TrackingState, awaitingRecognition: Bool, t: TimeInterval, now: TimeInterval) {
        if case .limited(.excessiveMotion) = state { fastSince = fastSince ?? now } else { fastSince = nil }
        if case .limited(.insufficientFeatures) = state { bareSince = bareSince ?? now } else { bareSince = nil }
        if let s = fastSince, now - s > 1.5 { fastSince = now; onHint?(.moveSlower) }
        if let s = bareSince, now - s > 3 { bareSince = now; onHint?(.moreFeatures) }
        if awaitingRecognition, t > 4 { onHint?(.lookAround) }
    }

    private func status(_ t: TimeInterval, awaitingRecognition: Bool, now: TimeInterval) -> String {
        let map = "map " + Self.describe(mapping) + (savedAt.map { String(format: ", saved %.0f s ago", now - $0) } ?? "")
        if awaitingRecognition { return String(format: "Recognising the room… %.0f s · move the iPhone slowly", t) }
        if let after = recognisedAfter, t - after < 20 { return String(format: "Room recognised after %.1f s · %@", after, map) }
        if let at = newRoomAt, now - at < 20 { return "New room: Pip maps it as you go · \(map)" }
        return ""
    }

    static func describe(_ s: ARCamera.TrackingState) -> String {
        switch s {
        case .normal: return "normal"
        case .notAvailable: return "not available"
        case .limited(.initializing): return "initializing"
        case .limited(.relocalizing): return "relocalizing"
        case .limited(.excessiveMotion): return "too much motion"
        case .limited(.insufficientFeatures): return "too few features"
        case .limited: return "limited"
        }
    }

    static func describe(_ m: ARFrame.WorldMappingStatus) -> String {
        switch m {
        case .notAvailable: return "none"
        case .limited: return "limited"
        case .extending: return "extending"
        case .mapped: return "mapped"
        @unknown default: return "?"
        }
    }

    private static let appendQueue = DispatchQueue(label: "pip.relocalise.log")

    static func log(_ line: String) {
        let text = ISO8601DateFormatter().string(from: Date()) + "\t" + line + "\n"
        appendQueue.async {
            let url = EdgeTAMSpike.documents.appendingPathComponent("relocalise.log")
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(text.utf8))
                try? h.close()
            } else {
                try? Data(text.utf8).write(to: url)
            }
        }
    }
}
