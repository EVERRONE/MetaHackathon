import ARKit
import Foundation
import simd

/// Decides which camera frames are good enough to go into Pip's map and visual memory, the way
/// mapping systems keep their maps clean: only with settled, normal tracking (a moment after it
/// comes back), not while the phone moves fast, not in the dark, and not when blurred. When
/// tracking breaks or the pose jumps, what was recorded just before is suspect: `onTrouble`
/// tells the map and the visual memory to drop it.
@MainActor
final class CaptureGate {
    /// Normal tracking this long before frames count again; longer after it was lost.
    static let settle: TimeInterval = 1
    static let settleAfterLoss: TimeInterval = 2
    /// Frames from this long before trouble are dropped.
    static let suspectBefore: TimeInterval = 1
    /// Faster than this the image smears and the pose lags.
    static let maxSpeed: Float = 1.2
    static let maxTurnSpeed: Float = 100 * .pi / 180
    /// A jump this big between two frames is tracking correcting itself, not the user moving.
    static let jump: Float = 0.08
    static let minLight: CGFloat = 80

    private var normalSince: TimeInterval?
    private var lostAt: TimeInterval?
    private var lastPose: simd_float4x4?
    private var lastTime: TimeInterval = 0
    private var speed: Float = 0
    private var turnSpeed: Float = 0
    /// Sharpness of recent accepted frames (variance of the image's Laplacian), for a relative test.
    private var sharpness: Double = 0
    private var sharpnessSamples = 0

    /// Something went wrong at this moment: drop what was recorded since `since`.
    var onTrouble: ((Date) -> Void)?

    /// Called for every camera frame.
    func update(_ frame: ARFrame) {
        let t = frame.timestamp
        let pose = frame.camera.transform
        if case .normal = frame.camera.trackingState {
            if normalSince == nil { normalSince = t }
        } else if normalSince != nil {
            trouble(at: t, lost: true)
        }
        if let last = lastPose, t > lastTime {
            let dt = Float(t - lastTime)
            let move = simd_distance(last.columns.3, pose.columns.3)
            let a = simd_make_float3(last.columns.2), b = simd_make_float3(pose.columns.2)
            let turn = acos(max(-1, min(1, simd_dot(simd_normalize(a), simd_normalize(b)))))
            // A pose jump within one frame: ARKit corrected itself.
            if move > Self.jump, dt < 0.05, normalSince != nil { trouble(at: t, lost: false) }
            speed = 0.7 * speed + 0.3 * move / dt
            turnSpeed = 0.7 * turnSpeed + 0.3 * turn / dt
        }
        lastPose = pose
        lastTime = t
    }

    private func trouble(at t: TimeInterval, lost: Bool) {
        normalSince = lost ? nil : t
        lostAt = lost ? t : lostAt
        onTrouble?(Date().addingTimeInterval(-Self.suspectBefore))
    }

    /// Whether this frame may go into the map or the visual memory. Sharpness is measured only
    /// here, for frames that would be kept.
    func accepts(_ frame: ARFrame) -> Bool {
        let t = frame.timestamp
        guard case .normal = frame.camera.trackingState, let since = normalSince else { return false }
        let settle = lostAt.map { since - $0 < 5 } == true ? Self.settleAfterLoss : Self.settle
        guard t - since >= settle, speed < Self.maxSpeed, turnSpeed < Self.maxTurnSpeed else { return false }
        if let light = frame.lightEstimate?.ambientIntensity, light < Self.minLight { return false }
        let s = Self.sharpness(frame.capturedImage)
        // Blurred compared with what this camera usually gives here (after a few frames to learn).
        if sharpnessSamples >= 8, s < 0.45 * sharpness { return false }
        sharpness = sharpnessSamples == 0 ? s : 0.9 * sharpness + 0.1 * s
        sharpnessSamples += 1
        return true
    }

    /// Variance of the Laplacian on a coarse grid of the luma plane: low when the image is blurred.
    nonisolated static func sharpness(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) >= 1, let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return 0 }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let step = 4
        var sum = 0.0, sumSq = 0.0, n = 0.0
        var y = step
        while y < h - step {
            var x = step
            while x < w - step {
                let c = Int(luma[y * row + x])
                let lap = Int(luma[y * row + x - step]) + Int(luma[y * row + x + step]) + Int(luma[(y - step) * row + x]) + Int(luma[(y + step) * row + x]) - 4 * c
                sum += Double(lap)
                sumSq += Double(lap * lap)
                n += 1
                x += step * 2
            }
            y += step * 2
        }
        guard n > 0 else { return 0 }
        let mean = sum / n
        return sumSq / n - mean * mean
    }
}
