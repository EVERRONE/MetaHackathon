import RealityKit
import UIKit

/// What the user saw, kept for judging a test afterwards: while a cue is drawn, every two seconds
/// the camera view and the cues together (Documents/overlay/<run>/NNN.jpg). Only on this iPhone;
/// the last few runs are kept. The cues are rendered at once and the camera image at its next
/// frame, so in a fast turn the two can be a frame apart.
final class OverlayShots {
    static let every: TimeInterval = 2
    static let maxPerRun = 60
    static let keepRuns = 5

    private var lastShot: TimeInterval = 0
    private var count = 0
    private var folder: URL?
    private let queue = DispatchQueue(label: "pip.overlayshots", qos: .utility)

    func frame(now: TimeInterval, cuesDrawn: Bool, arView: ARView, overlay: UIView) {
        guard cuesDrawn, now - lastShot >= Self.every, count < Self.maxPerRun, overlay.bounds.width > 0, !overlay.isHidden else { return }
        lastShot = now
        count += 1
        let index = count
        guard let folder = folder ?? startRun() else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let size = overlay.bounds.size
        let cues = UIGraphicsImageRenderer(size: size, format: format).image { overlay.layer.render(in: $0.cgContext) }
        arView.snapshot(saveToHDR: false) { [queue] camera in
            guard let camera else { return }
            queue.async {
                let opaque = UIGraphicsImageRendererFormat()
                opaque.scale = 2
                opaque.opaque = true
                let image = UIGraphicsImageRenderer(size: size, format: opaque).image { _ in
                    camera.draw(in: CGRect(origin: .zero, size: size))
                    cues.draw(in: CGRect(origin: .zero, size: size))
                }
                try? image.jpegData(compressionQuality: 0.75)?.write(to: folder.appendingPathComponent(String(format: "%03d.jpg", index)))
            }
        }
    }

    private func startRun() -> URL? {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("overlay")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = base.appendingPathComponent(stamp)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        let runs = ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
            .filter(\.hasDirectoryPath).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in runs.dropLast(Self.keepRuns) { try? FileManager.default.removeItem(at: old) }
        folder = dir
        return dir
    }
}
