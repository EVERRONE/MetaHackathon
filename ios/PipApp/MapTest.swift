import ARKit
import Foundation

/// Spike T3 (docs/research-precision.md): one home map, recognised at every start, the way the
/// home tier should work. With the test on (memory sheet, then restart the app), Pip hands ARKit
/// the home map at launch and keeps waiting until ARKit recognises it (no give-up after 8 s); the
/// cues stay hidden until then. It logs how long that takes, in which light, and the map's state,
/// to Documents/maptest.log. The home map is saved only once ARKit has mapped the area
/// (`.mapped`), and only from a session that recognised it (or when there is none yet): on the
/// button in the memory sheet and when the app goes to the background. Three older versions stay.
final class MapTest {
    static let enabledKey = "pip.mapTest"
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var folder: URL { EdgeTAMSpike.documents.appendingPathComponent("maptest") }
    static var mapURL: URL { folder.appendingPathComponent("home.worldmap") }
    static let versions = 3

    private(set) var homeMap: ARWorldMap?
    private let launched = CACurrentMediaTime()
    /// Seconds from launch until ARKit recognised the home map.
    private(set) var recognisedAfter: TimeInterval?
    private(set) var mapping: ARFrame.WorldMappingStatus = .notAvailable
    private var lastState = ""
    private var lastMapping: ARFrame.WorldMappingStatus?
    private var lastPeriodic: TimeInterval = 0
    private var lastStatus: TimeInterval = 0
    private var firstLight: CGFloat?
    var onStatus: ((String) -> Void)?

    init() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: Self.mapURL) else {
            homeMap = nil
            Self.log("launch: no home map yet")
            return
        }
        homeMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
        let age = (try? FileManager.default.attributesOfItem(atPath: Self.mapURL.path)[.modificationDate] as? Date).map { Date().timeIntervalSince($0) } ?? -1
        if let m = homeMap {
            Self.log(String(format: "launch: home map %.1f MB, %.1f h old, %d feature points, %d anchors, extent %.1f×%.1f×%.1f m",
                            Double(data.count) / 1e6, age / 3600, m.rawFeaturePoints.points.count, m.anchors.count,
                            m.extent.x, m.extent.y, m.extent.z))
        } else {
            Self.log("launch: home map unreadable")
        }
    }

    /// Whether a map from this session may replace the home map.
    var maySave: Bool { homeMap == nil || recognisedAfter != nil }

    /// Every camera frame.
    func frame(_ frame: ARFrame) {
        let t = CACurrentMediaTime() - launched
        let light = frame.lightEstimate?.ambientIntensity ?? -1
        if firstLight == nil, light >= 0 { firstLight = light }
        mapping = frame.worldMappingStatus
        let state = Self.describe(frame.camera.trackingState)
        if state != lastState || mapping != lastMapping {
            lastState = state
            lastMapping = mapping
            Self.log(String(format: "%.1f s: %@, map %@, light %.0f lm, %d features", t, state, Self.describe(mapping), light,
                            frame.rawFeaturePoints?.points.count ?? 0))
        }
        if homeMap != nil, recognisedAfter == nil, case .normal = frame.camera.trackingState {
            recognisedAfter = t
            let p = frame.camera.transform.columns.3
            Self.log(String(format: "RECOGNISED after %.1f s (light at start %.0f lm, now %.0f lm), at %.2f, %.2f, %.2f",
                            t, firstLight ?? -1, light, p.x, p.y, p.z))
        }
        if homeMap != nil, recognisedAfter == nil, t - lastPeriodic >= 5 {
            lastPeriodic = t
            Self.log(String(format: "%.0f s: still recognising (light %.0f lm, %d features, map %@)", t, light,
                            frame.rawFeaturePoints?.points.count ?? 0, Self.describe(mapping)))
        }
        if t - lastStatus >= 0.5 {
            lastStatus = t
            onStatus?(status(t))
        }
    }

    private func status(_ t: TimeInterval) -> String {
        let map = "map " + Self.describe(mapping)
        guard homeMap != nil else { return "Map test: no home map yet · \(map) · walk around, then save it" }
        if let after = recognisedAfter { return String(format: "Map test: recognised after %.1f s · %@", after, map) }
        return String(format: "Map test: recognising… %.0f s · look at a spot you scanned before", t)
    }

    /// Saves this session's map as the home map when that is allowed now; says why not otherwise.
    func save(_ ar: ARController, reason: String, done: @escaping (String) -> Void) {
        guard maySave else { done("Not saved: the home map has not been recognised yet."); return }
        guard mapping == .mapped else { done("Not saved: the map is not complete yet (\(Self.describe(mapping))). Walk around a little more."); return }
        ar.currentWorldMap { [weak self] map in
            guard let self else { return }
            guard let map, let data = try? NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true) else {
                done("Not saved: ARKit gave no map.")
                return
            }
            let fm = FileManager.default
            // home.worldmap → home.1 → home.2 → home.3
            for k in stride(from: Self.versions - 1, through: 0, by: -1) {
                let from = k == 0 ? Self.mapURL : Self.folder.appendingPathComponent("home.\(k).worldmap")
                let to = Self.folder.appendingPathComponent("home.\(k + 1).worldmap")
                if fm.fileExists(atPath: from.path) {
                    try? fm.removeItem(at: to)
                    try? fm.moveItem(at: from, to: to)
                }
            }
            do {
                try data.write(to: Self.mapURL, options: .completeFileProtectionUntilFirstUserAuthentication)
                if self.homeMap == nil { self.recognisedAfter = 0 }
                self.homeMap = map
                Self.log(String(format: "saved (%@): %.1f MB, %d feature points, %d anchors, extent %.1f×%.1f×%.1f m", reason,
                                Double(data.count) / 1e6, map.rawFeaturePoints.points.count, map.anchors.count, map.extent.x, map.extent.y, map.extent.z))
                done("Home map saved.")
            } catch {
                done("Not saved: \(error.localizedDescription)")
            }
        }
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

    private static let appendQueue = DispatchQueue(label: "pip.maptest.log")

    static func log(_ line: String) {
        let text = ISO8601DateFormatter().string(from: Date()) + "\t" + line + "\n"
        appendQueue.async {
            let url = EdgeTAMSpike.documents.appendingPathComponent("maptest.log")
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
