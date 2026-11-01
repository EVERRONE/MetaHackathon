import Foundation
import PipCore
import UIKit

/// Saves every look on the device (frame, events, outlines, timings) so it can be replayed and
/// evaluated on the Mac: part of the test record (Documents/looks, see Diagnostics).
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
        guard let dir = Diagnostics.newRun(in: "looks", named: formatter.string(from: Date()), keep: Self.keep) else { return nil }
        self.dir = dir
        // Encoding and writing happen off the main thread, so the AR view does not hitch.
        Diagnostics.write(to: dir.appendingPathComponent("frame.jpg")) { SetOfMarks.jpeg(frame, quality: 0.9) }
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
        let text = lines.joined(separator: "\n"), instances = instances
        Diagnostics.write(to: dir.appendingPathComponent("log.txt")) { Data(text.utf8) }
        Diagnostics.write(to: dir.appendingPathComponent("instances.json")) { try? JSONEncoder().encode(instances) }
    }
}
