import ARKit
import Foundation

/// Watches how well the room is being mapped, without the user doing anything: it logs ARKit's
/// tracking and mapping states (to Documents/relocalise.log, the log of linking sessions too),
/// shows a line on screen at the start, and says when the user should move more slowly or show it
/// more of the room for the mapping to work (see GuideModel+Memory). Tracking always starts fresh,
/// in a new map piece.
final class Relocalisation {
    enum Hint { case moveSlower, moreFeatures }

    private var startedAt = CACurrentMediaTime()
    private(set) var mapping: ARFrame.WorldMappingStatus = .notAvailable
    private var lastState = ""
    private var lastMapping: ARFrame.WorldMappingStatus?
    private var lastStatus: TimeInterval = 0
    private var savedAt: TimeInterval?
    /// Since when ARKit has said the phone moves too fast, or sees too little.
    private var fastSince: TimeInterval?
    private var bareSince: TimeInterval?
    var onStatus: ((String) -> Void)?
    var onHint: ((Hint) -> Void)?

    /// Tracking started, in a new map piece (`detail`: what is stored, for the log).
    func started(detail: String) {
        startedAt = CACurrentMediaTime()
        Self.log("mapping a new piece (\(detail))")
    }

    func saved(_ ok: Bool, detail: String) {
        if ok { savedAt = CACurrentMediaTime() }
        Self.log((ok ? "map saved: " : "map not saved: ") + detail)
    }

    /// Every camera frame.
    func frame(_ frame: ARFrame) {
        let now = CACurrentMediaTime()
        let t = now - startedAt
        let light = frame.lightEstimate?.ambientIntensity ?? -1
        mapping = frame.worldMappingStatus
        let state = Self.describe(frame.camera.trackingState)
        if state != lastState || mapping != lastMapping {
            lastState = state
            lastMapping = mapping
            Self.log(String(format: "%.1f s: %@, map %@, light %.0f lm, %d features", t, state, Self.describe(mapping), light,
                            frame.rawFeaturePoints?.points.count ?? 0))
        }
        hints(frame.camera.trackingState, now: now)
        if now - lastStatus >= 0.5 {
            lastStatus = now
            onStatus?(status(t, now: now))
        }
    }

    private func hints(_ state: ARCamera.TrackingState, now: TimeInterval) {
        if case .limited(.excessiveMotion) = state { fastSince = fastSince ?? now } else { fastSince = nil }
        if case .limited(.insufficientFeatures) = state { bareSince = bareSince ?? now } else { bareSince = nil }
        if let s = fastSince, now - s > 1.5 { fastSince = now; onHint?(.moveSlower) }
        if let s = bareSince, now - s > 3 { bareSince = now; onHint?(.moreFeatures) }
    }

    /// For the first 20 s: that this room is being mapped, and how far.
    private func status(_ t: TimeInterval, now: TimeInterval) -> String {
        let map = "map " + Self.describe(mapping) + (savedAt.map { String(format: ", saved %.0f s ago", now - $0) } ?? "")
        return t < 20 ? "New room: Pip maps it as you go · \(map)" : ""
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

    static func log(_ line: String) { Diagnostics.log(line, to: "relocalise.log") }
}
