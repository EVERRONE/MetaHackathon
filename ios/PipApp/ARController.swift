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

    func start() {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        arView.renderOptions.insert(.disableMotionBlur)
        arView.session.delegate = self
        arView.session.run(config)
    }

    func snapshot() -> FrameSnapshot? {
        arView.session.currentFrame.flatMap { FrameSnapshot(frame: $0) }
    }

    /// A new look: marks from the previous one no longer apply. Mark numbers restart each look,
    /// so a danger from the last look must go too, or it would land on this look's mark 1.
    func beginLook() {
        marks = [:]
        board.show(.clear, at: CACurrentMediaTime())
        board.resolveDanger()
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
