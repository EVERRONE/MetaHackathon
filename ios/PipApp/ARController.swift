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
        marks[inst.id] = m
        return m.method
    }

    func show(_ cue: Cue) {
        if replacePending, cue.isDrawn {
            // The new answer points somewhere: earlier cues and their marks give way.
            replacePending = false
            board.show(.clear, at: CACurrentMediaTime())
            board.resolveDanger()
            marks = marks.filter { $0.key >= currentOffset }
        }
        board.show(cue, at: CACurrentMediaTime())
        renderNow()
    }

    func clearCues() {
        board.show(.clear, at: CACurrentMediaTime())
        board.resolveDanger()
        renderNow()
    }


    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        renderNow()
    }


    private func renderNow() {
        let now = CACurrentMediaTime()
        board.tick(now)
        overlay.render(board.annotations, now: now, marks: marks) { [arView] p in arView.project(p) }
    }
}
