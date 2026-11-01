import Foundation
import simd

/// Every re-measurement of a pointed-at object: how far the drawn outline was from the object
/// before the correction (pixels in a 1280 px frame), why it was measured, and how many views
/// the position rests on. One line each in Documents/tracking.log (the test record, see
/// Diagnostics), so how well outlines hold can be measured from real use.
@MainActor
final class TrackingLog {
    func record(id: Int, reason: ObjectTrack.Reason, update: ObjectTrack.Update) {
        let line = String(format: "%@\t%d\t%@\t%.1f\t%.2f\t%d\t%@\t%.1f\t%@\n", ISO8601DateFormatter().string(from: Date()), id, reason.rawValue,
                          update.pixelError ?? -1, update.correction * 100, update.views, update.reset ? "reset" : "fused",
                          (update.offset.map { simd_length($0) } ?? 0) * 100, update.method)
        Diagnostics.append(line, to: "tracking.log", header: "time\tmark\treason\tpx_off\tcorrected_cm\tviews\tkind\tdrift_cm\tmethod\n")
    }
}
