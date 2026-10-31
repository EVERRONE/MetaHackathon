import ARKit
import PipCore
import QuartzCore
import RealityKit

/// Owns the AR session, the anchored marks and what is drawn on them each frame.
final class ARController: NSObject, ObservableObject, ARSessionDelegate {
    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    let overlay = OverlayView()

    @Published private(set) var trackingNormal = false
    @Published private(set) var hasLiDAR = false

    private(set) var board = AnnotationBoard()
    private var marks: [Int: AnchoredMark] = [:]
    private var instances: [Int: SegmentInstance] = [:]

    func start() {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
            hasLiDAR = true
        }
        arView.renderOptions.insert(.disableMotionBlur)
        arView.session.delegate = self
        arView.session.run(config)
    }

    func snapshot() -> FrameSnapshot? {
        arView.session.currentFrame.flatMap { FrameSnapshot(frame: $0) }
    }

    /// A new look: marks from the previous one no longer apply.
    func beginLook() {
        instances = [:]
        marks = [:]
        board.show(.clear, at: CACurrentMediaTime())
    }

    /// Lifts one grounded instance into 3D. Returns how it was anchored, for the trace.
    @discardableResult
    func addMark(_ inst: SegmentInstance, snapshot: FrameSnapshot) -> String {
        instances[inst.id] = inst
        guard let m = AnchoredMark(inst, snapshot: snapshot) else { return "no depth" }
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

    var anchoredCount: Int { marks.count }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        renderNow()
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        if case .normal = camera.trackingState { trackingNormal = true } else { trackingNormal = false }
    }

    private func renderNow() {
        let now = CACurrentMediaTime()
        board.tick(now)
        overlay.render(board.annotations, now: now, marks: marks) { [arView] p in arView.project(p) }
    }
}
