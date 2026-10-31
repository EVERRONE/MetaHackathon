import Foundation
import PipCore
import UIKit

/// Saves every look on the device (frame, events, outlines, timings) so it can be replayed and
/// evaluated on the Mac. Pull with:
///   xcrun devicectl device copy from --device <udid> --domain-type appDataContainer \
///     --domain-identifier be.unveil.pip.dev --source Documents/looks --destination <dir>
final class LookRecorder {
    private let dir: URL
    private let start = Date()
    private var lines: [String] = []
    private var instances: [SegmentInstance] = []

    /// Looks kept on the device; older ones are deleted.
    static let keep = 40

    init?(utterance: String, language: String, frame: CGImage) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS"
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let root = docs.appendingPathComponent("looks")
        dir = root.appendingPathComponent(formatter.string(from: Date()))
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        let dir = dir
        // Encoding and writing happen off the main thread, so the AR view does not hitch.
        Task.detached(priority: .utility) {
            if let jpeg = SetOfMarks.jpeg(frame, quality: 0.9) { try? jpeg.write(to: dir.appendingPathComponent("frame.jpg")) }
            Self.prune(root)
        }
        log("utterance (\(language)): \(utterance)")
    }

    private static func prune(_ root: URL) {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
        for name in all.dropLast(keep) { try? FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
    }

    func log(_ line: String) {
        lines.append(String(format: "%6.2f  ", Date().timeIntervalSince(start)) + line)
    }

    func grounded(_ inst: SegmentInstance) {
        instances.append(inst)
    }

    func finish(rawText: String?) {
        if let rawText { lines.append("--- raw ---\n" + rawText) }
        let text = lines.joined(separator: "\n"), instances = instances, dir = dir
        Task.detached(priority: .utility) {
            try? text.write(to: dir.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
            if let data = try? JSONEncoder().encode(instances) { try? data.write(to: dir.appendingPathComponent("instances.json")) }
        }
    }
}
