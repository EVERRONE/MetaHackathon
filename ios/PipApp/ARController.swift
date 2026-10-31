import ARKit
import PipCore
import QuartzCore
import RealityKit

/// Owns the AR session, the anchored marks and what is drawn on them each frame.
final class ARController: NSObject, ObservableObject, ARSessionDelegate {
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    let overlay = OverlayView()

    private(set) var board = AnnotationBoard()
    private var marks: [Int: AnchoredMark] = [:]
    /// Each mark's ARKit anchor and where it was when the mark was placed.
    private var anchors: [Int: (anchor: ARAnchor, origin: simd_float4x4)] = [:]
    /// False while ARKit has lost the room (after leaving it): cues are hidden, not drawn wrong.
    @Published private(set) var trackingNormal = true
    private var currentOffset = 0
    private var replacePending = false

    func start() {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        // Depth averaged over recent frames: less noise, so outlines sit more exactly.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        arView.renderOptions.insert(.disableMotionBlur)
        arView.session.delegate = self
        arView.session.run(config)
    }

    func snapshot() -> FrameSnapshot? {
        arView.session.currentFrame.flatMap { FrameSnapshot(frame: $0) }
    }

    /// A new look. The previous look's cues stay on their objects until this look shows its first
    /// cue, so the user keeps their bearings while Pip thinks, or when the answer points at nothing.
    func beginLook(markOffset: Int) {
        currentOffset = markOffset
        replacePending = true
    }

    /// Lifts one grounded instance into 3D. Returns how it was anchored, for the trace.
    @discardableResult
    func addMark(_ inst: SegmentInstance, snapshot: FrameSnapshot) -> String {
        // Clean, regular shapes: a raw mask outline looks hand-drawn once stroked on screen.
        guard let m = AnchoredMark(inst.regularized(), snapshot: snapshot) else { return "no outline" }
        place(m)
        return m.method
    }

    /// Replaces a mark with a fresh measurement of the same object (it moved, or the user came back).
    @discardableResult
    func updateMark(_ inst: SegmentInstance, snapshot: FrameSnapshot) -> Bool {
        guard marks[inst.id] != nil, let m = AnchoredMark(inst.regularized(), snapshot: snapshot) else { return false }
        place(m)
        return true
    }

    private func place(_ m: AnchoredMark) {
        if let old = anchors[m.id] { arView.session.remove(anchor: old.anchor) }
        var t = matrix_identity_float4x4
        t.columns.3 = simd_float4(m.placement, 1)
        let anchor = ARAnchor(name: "pip-mark", transform: t)
        arView.session.add(anchor: anchor)
        anchors[m.id] = (anchor, t)
        marks[m.id] = m
    }

    private func removeMarks(where shouldRemove: (Int) -> Bool) {
        for id in marks.keys where shouldRemove(id) {
            if let a = anchors[id] { arView.session.remove(anchor: a.anchor) }
            anchors[id] = nil
            marks[id] = nil
        }
    }

    /// Marks with a cue on screen, and their outline's box in the snapshot's pixels.
    func visibleMarkBoxes(in snapshot: FrameSnapshot) -> [(id: Int, box: CGRect)] {
        let shown = Set(board.annotations.flatMap { $0.cue.marks })
        let bounds = CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height)
        return shown.compactMap { id -> (Int, CGRect)? in
            guard let m = marks[id] else { return nil }
            let pts = m.polygons.flatMap { $0 }.compactMap(snapshot.project)
            guard pts.count >= 3 else { return nil }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            return bounds.intersects(box) && box.width > 4 && box.height > 4 ? (id, box) : nil
        }.sorted { $0.0 < $1.0 }
    }

    func show(_ cue: Cue) {
        if replacePending, cue.isDrawn {
            // The new answer points somewhere: earlier cues and their marks give way.
            replacePending = false
            board.show(.clear, at: CACurrentMediaTime())
            board.resolveDanger()
            let keepFrom = currentOffset
            removeMarks { $0 < keepFrom }
        }
        board.show(cue, at: CACurrentMediaTime())
        renderNow()
    }

    /// A step was seen done: its pointing turns into a short green check.
    func markVerified() {
        let now = CACurrentMediaTime()
        let shown = board.annotations.filter { $0.lifetime == .untilVerified }.flatMap { $0.cue.marks }
        for m in Set(shown) where marks[m] != nil { board.show(.verified(mark: m), at: now) }
        renderNow()
    }

    func clearCues() {
        board.show(.clear, at: CACurrentMediaTime())
        board.resolveDanger()
        renderNow()
    }


    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // ARKit moves anchors when it corrects its map (loop closure, relocalisation).
        if !anchors.isEmpty {
            let current = Dictionary(frame.anchors.map { ($0.identifier, $0.transform) }, uniquingKeysWith: { a, _ in a })
            for (id, entry) in anchors {
                guard let now = current[entry.anchor.identifier] else { continue }
                marks[id]?.correction = now * simd_inverse(entry.origin)
            }
        }
        renderNow()
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        if case .normal = camera.trackingState { trackingNormal = true } else { trackingNormal = false }
        overlay.isHidden = !trackingNormal
    }


    private func renderNow() {
        let now = CACurrentMediaTime()
        board.tick(now)
        overlay.render(board.annotations, now: now, marks: marks) { [arView] p in arView.project(p) }
    }
}
