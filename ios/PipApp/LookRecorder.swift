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

    init?(utterance: String, language: String, frame: CGImage) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        dir = docs.appendingPathComponent("looks").appendingPathComponent(stamp)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        if let jpeg = SetOfMarks.jpeg(frame, quality: 0.9) { try? jpeg.write(to: dir.appendingPathComponent("frame.jpg")) }
        log("utterance (\(language)): \(utterance)")
    }

    func log(_ line: String) {
        lines.append(String(format: "%6.2f  ", Date().timeIntervalSince(start)) + line)
    }

    func grounded(_ inst: SegmentInstance) {
        instances.append(inst)
    }

    func finish(rawText: String?) {
        if let rawText { lines.append("--- raw ---\n" + rawText) }
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        if let data = try? JSONEncoder().encode(instances) { try? data.write(to: dir.appendingPathComponent("instances.json")) }
    }
}
