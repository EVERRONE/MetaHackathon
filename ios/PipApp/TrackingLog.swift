import Foundation
import simd

/// Every re-measurement of a pointed-at object: how far the drawn outline was from the object
/// before the correction (pixels in a 1280 px frame), why it was measured, and how many views
/// the position rests on. Written to Documents/tracking.log, one line each, so how well outlines
/// hold can be measured from real use. Pull with:
///   xcrun devicectl device copy from --device <udid> --domain-type appDataContainer \
///     --domain-identifier be.unveil.pip.dev --source Documents/tracking.log --destination <dir>
@MainActor
final class TrackingLog {
    private let url: URL?
    private var errors: [Double] = []

    init() {
        url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("tracking.log")
    }

    func record(id: Int, reason: ObjectTrack.Reason, update: ObjectTrack.Update) {
        if let e = update.pixelError { errors.append(e) }
        let line = String(format: "%@\t%d\t%@\t%.1f\t%d\t%@\t%.1f\t%@\n", ISO8601DateFormatter().string(from: Date()), id, reason.rawValue,
                          update.pixelError ?? -1, update.views, update.reset ? "reset" : "fused",
                          (update.offset.map { simd_length($0) } ?? 0) * 100, update.method)
        guard let url else { return }
        Task.detached(priority: .utility) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(("time\tmark\treason\tpx_off\tviews\tkind\tdrift_cm\tmethod\n" + line).utf8).write(to: url)
            }
        }
    }

    /// Appends a time-stamped line to a file in Documents, off the main thread.
    nonisolated static func append(_ line: String, to name: String) {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(name) else { return }
        let text = ISO8601DateFormatter().string(from: Date()) + "\t" + line + "\n"
        Task.detached(priority: .utility) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            } else {
                try? Data(text.utf8).write(to: url)
            }
        }
    }

    /// Median distance between outline and object over this session's re-measurements.
    var medianError: Double? {
        guard !errors.isEmpty else { return nil }
        return errors.sorted()[errors.count / 2]
    }
}
