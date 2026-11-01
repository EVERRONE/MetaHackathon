import RealityKit
import UIKit

/// What the user saw, kept for judging a test afterwards: while a cue is drawn, every two seconds
/// the camera view and the cues together (Documents/overlay/<run>/NNN.jpg, the test record, see
/// Diagnostics); the last few runs are kept. The cues are rendered at once and the camera image at its next
/// frame, so in a fast turn the two can be a frame apart.
final class OverlayShots {
    static let every: TimeInterval = 2
    static let maxPerRun = 60
    static let keepRuns = 5

    private var lastShot: TimeInterval = 0
    private var count = 0
    private var folder: URL?

    func frame(now: TimeInterval, cuesDrawn: Bool, arView: ARView, overlay: UIView) {
        guard Diagnostics.enabled, cuesDrawn, now - lastShot >= Self.every, count < Self.maxPerRun, overlay.bounds.width > 0, !overlay.isHidden else { return }
        lastShot = now
        count += 1
        let index = count
        guard let folder = folder ?? startRun() else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let size = overlay.bounds.size
        let cues = UIGraphicsImageRenderer(size: size, format: format).image { overlay.layer.render(in: $0.cgContext) }
        arView.snapshot(saveToHDR: false) { camera in
            guard let camera else { return }
            Diagnostics.write(to: folder.appendingPathComponent(String(format: "%03d.jpg", index))) {
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
