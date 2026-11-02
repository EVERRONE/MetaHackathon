import RealityKit
import UIKit

/// What the user saw, kept for judging a test afterwards: while a cue is drawn, every two seconds
/// the camera view and the cues together (Documents/overlay/<run>/NNN-HHmmss.jpg, the test record,
/// see Diagnostics). A pointing after a pause starts a run of its own, so every answer's cues are
/// kept (2 Nov: one run per session stopped after 60 shots, before the arrow to the remembered
/// pen); the last runs are kept. The name carries the time the shot was taken: the files are
/// written later, on a busy phone up to half a minute later. The cues are rendered at once and the
/// camera image at its next frame, so in a fast turn the two can be a frame apart.
final class OverlayShots {
    static let every: TimeInterval = 2
    static let maxPerRun = 60
    static let keepRuns = 20
    /// Cues drawn again after this long without: a new pointing, in a run of its own.
    static let newRunAfter: TimeInterval = 5

    private var lastShot: TimeInterval = 0
    private var lastDrawn: TimeInterval = 0
    private var count = 0
    private var folder: URL?
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        return f
    }()

    func frame(now: TimeInterval, cuesDrawn: Bool, arView: ARView, overlay: UIView) {
        guard Diagnostics.enabled, cuesDrawn else { return }
        if now - lastDrawn > Self.newRunAfter {
            folder = nil
            count = 0
        }
        lastDrawn = now
        guard now - lastShot >= Self.every, count < Self.maxPerRun, overlay.bounds.width > 0, !overlay.isHidden else { return }
        lastShot = now
        count += 1
        let index = count
        let taken = Self.clock.string(from: Date())
        guard let folder = folder ?? startRun() else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let size = overlay.bounds.size
        let cues = UIGraphicsImageRenderer(size: size, format: format).image { overlay.layer.render(in: $0.cgContext) }
        arView.snapshot(saveToHDR: false) { camera in
            guard let camera else { return }
            Diagnostics.write(to: folder.appendingPathComponent(String(format: "%03d-%@.jpg", index, taken))) {
                let opaque = UIGraphicsImageRendererFormat()
                opaque.scale = 2
                opaque.opaque = true
                let image = UIGraphicsImageRenderer(size: size, format: opaque).image { _ in
                    camera.draw(in: CGRect(origin: .zero, size: size))
                    cues.draw(in: CGRect(origin: .zero, size: size))
                }
                return image.jpegData(compressionQuality: 0.75)
            }
        }
    }

    private func startRun() -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        folder = Diagnostics.newRun(in: "overlay", named: stamp, keep: Self.keepRuns)
        return folder
    }
}
