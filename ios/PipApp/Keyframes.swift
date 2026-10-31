import ARKit
import Foundation
import PipCore
import simd

/// Pip's visual memory: a small snapshot whenever the camera sees something new, with where the
/// phone was and how far away things were, so "where did I leave my drink?" can be answered later.
/// Kept on this iPhone only, for the last 30 minutes.
@MainActor
final class Keyframes {
    struct Frame {
        let id: Int
        let time: Date
        /// About 768 px on the long side.
        let jpeg: Data
        let width: Int
        let height: Int
        let cameraTransform: simd_float4x4
        /// The captured image's size and intrinsics (sensor orientation), as in FrameSnapshot.
        let sensorSize: CGSize
        let intrinsics: simd_float3x3
        /// Depth in metres, 64×48 in the upright image's orientation, 0 where unknown.
        let depth: [Float16]
        static let depthW = 48, depthH = 64

        /// The depth at a pixel: the median of the known samples around it.
        func depth(atPixel p: CGPoint) -> Float? {
            let dx = Int(p.x / CGFloat(width) * CGFloat(Self.depthW)), dy = Int(p.y / CGFloat(height) * CGFloat(Self.depthH))
            var samples: [Float] = []
            for y in max(0, dy - 1)...min(Self.depthH - 1, dy + 1) {
                for x in max(0, dx - 1)...min(Self.depthW - 1, dx + 1) {
                    let d = Float(depth[y * Self.depthW + x])
                    if d > 0.05 { samples.append(d) }
                }
            }
            return samples.isEmpty ? nil : samples.sorted()[samples.count / 2]
        }

        /// The world point at a pixel of the stored image, at a given depth. Same mapping as
        /// FrameSnapshot: upright pixel → sensor pixel → camera space → world.
        func worldPoint(atPixel p: CGPoint, depth d: Float) -> simd_float3 {
            let s = sensorSize.width / CGFloat(height)
            let q = CGPoint(x: p.y * s, y: sensorSize.height - p.x * s)
            let fx = intrinsics[0][0], fy = intrinsics[1][1], cx = intrinsics[2][0], cy = intrinsics[2][1]
            let x = (Float(q.x) - cx) / fx * d
            let y = -(Float(q.y) - cy) / fy * d
            let w = cameraTransform * simd_float4(x, y, -d, 1)
            return simd_float3(w.x, w.y, w.z)
        }
    }

    static let keepFor: TimeInterval = 30 * 60
    static let maxFrames = 600

    private(set) var frames: [Frame] = []
    private var nextId = 1
    private var lastPose: simd_float4x4?
    private var lastTime: TimeInterval = 0

    /// Called for camera frames; keeps one when the view has changed enough. `trusted`: the
    /// app trusts tracking (also after it gave up waiting to recognise a saved room).
    func consider(_ frame: ARFrame, trusted: Bool) {
        switch frame.camera.trackingState {
        case .normal: break
        case .limited(.relocalizing) where trusted: break
        default: return
        }
        let t = frame.timestamp
        guard t - lastTime > 0.5 else { return }
        if let last = lastPose {
            let move = simd_distance(simd_make_float3(last.columns.3), simd_make_float3(frame.camera.transform.columns.3))
            let a = simd_make_float3(last.columns.2), b = simd_make_float3(frame.camera.transform.columns.2)
            let turn = acos(max(-1, min(1, simd_dot(simd_normalize(a), simd_normalize(b)))))
            guard move > 0.25 || turn > 20 * .pi / 180 || t - lastTime > 10 else { return }
        }
        lastTime = t
        lastPose = frame.camera.transform
        guard let snap = FrameSnapshot(frame: frame, maxSide: 768) else { return }
        let id = nextId
        nextId += 1
        let generation = self.generation
        // Encoding and depth sampling happen off the main thread, so the camera view does not hitch.
        Task.detached(priority: .utility) { [weak self] in
            guard let jpeg = SetOfMarks.jpeg(snap.image, quality: 0.6) else { return }
            let kept = Self.frame(id: id, snap: snap, jpeg: jpeg)
            await self?.keep(kept, generation: generation)
        }
    }

    private func keep(_ frame: Frame, generation: Int) {
        guard self.generation == generation else { return }
        frames.append(frame)
        let cutoff = Date().addingTimeInterval(-Self.keepFor)
        frames.removeAll { $0.time < cutoff }
        if frames.count > Self.maxFrames { frames.removeFirst(frames.count - Self.maxFrames) }
    }

    /// Bumped by `forgetAll`, so snapshots still being encoded are dropped.
    private var generation = 0

    func forgetAll() {
        frames = []
        lastPose = nil
        generation += 1
    }

    nonisolated private static func frame(id: Int, snap: FrameSnapshot, jpeg: Data) -> Frame {
        let w = snap.image.width, h = snap.image.height
        var depth = [Float16](repeating: 0, count: Frame.depthW * Frame.depthH)
        for y in 0..<Frame.depthH {
            for x in 0..<Frame.depthW {
                let p = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(Frame.depthW) * CGFloat(w), y: (CGFloat(y) + 0.5) / CGFloat(Frame.depthH) * CGFloat(h))
                depth[y * Frame.depthW + x] = Float16(snap.depth(atSensor: snap.sensorPoint(p), minConfidence: 1) ?? 0)
            }
        }
        return Frame(id: id, time: Date(), jpeg: jpeg, width: w, height: h, cameraTransform: snap.cameraTransform,
                     sensorSize: snap.sensorSize, intrinsics: snap.intrinsics, depth: depth)
    }
}
