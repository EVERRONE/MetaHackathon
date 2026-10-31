import ARKit
import Foundation
import PipCore
import Vision
import simd

/// Pip's map of the user's home, built while Pip is used, never scanned on purpose.
///
/// Every session builds a map piece in its own frame: the room's surfaces (ARKit's LiDAR mesh)
/// and, every metre or so, a map keyframe with an image fingerprint and the camera pose. Pieces
/// from earlier sessions are recognised the way a visual positioning system localises: a quick
/// image search proposes where this view was seen before, then the live depth points are laid
/// onto that piece's stored surfaces (upright, so only a turn and a shift). Two such fits from
/// different spots must agree before the pieces are linked; then the old piece, with its places,
/// moves into this session's frame and the two are one map from then on.
@MainActor
final class MapKeeper {
    /// The piece this session builds; its frame is this session's frame.
    private(set) var current = MapPiece()
    /// Pieces from earlier sessions, not linked into this one yet.
    private(set) var others: [MapPiece] = []
    private var targets: [UUID: RegistrationTarget] = [:]
    private var consensus = LinkConsensus()
    /// Pieces merged into this one: their files go once this piece is saved.
    private var merged: [UUID] = []
    private var lastKeyPose: simd_float4x4?
    private var lastKeyTime: TimeInterval = 0
    private var working = false
    /// Something changed since the last save.
    private(set) var dirty = false
    /// Only with the user's consent: without it nothing is kept beyond the session anyway.
    var enabled = false

    /// A piece was linked: the piece, and the transform from its frame into this session's.
    var onLink: ((MapPiece, simd_float4x4) -> Void)?
    var onLog: ((String) -> Void)?

    /// A keyframe when the phone moved this far, turned this much, or after this long.
    static let keyDistance: Float = 0.75
    static let keyTurnDegrees: Float = 25
    static let keyInterval: TimeInterval = 10
    static let maxKeyframes = 400
    /// Fingerprint distance beyond which a view is not even tried (the 3D fit decides).
    static let maxPrintDistance: Float = 1.2
    static let maxSurfacePoints = 250_000

    /// `piece`: the stored piece ARKit is relocalising into (its frame becomes this session's).
    func begin(continuing piece: MapPiece?, others: [MapPiece]) {
        current = piece ?? MapPiece()
        self.others = others
        targets = [:]
        consensus = LinkConsensus()
        merged = []
        lastKeyPose = nil
        dirty = false
    }

    /// ARKit did not recognise the room of the piece it tried: that piece waits to be linked
    /// like the others, and this session starts a piece of its own.
    func startNewPiece() {
        if !current.keyframes.isEmpty || !current.points.isEmpty { others.append(current) }
        current = MapPiece()
        lastKeyPose = nil
        dirty = false
    }

    func consider(_ frame: ARFrame) {
        guard enabled, !working, case .normal = frame.camera.trackingState else { return }
        let t = frame.timestamp
        let pose = frame.camera.transform
        if let last = lastKeyPose {
            let move = simd_distance(last.columns.3.xyz, pose.columns.3.xyz)
            let turn = abs(Self.wrapped(Self.heading(pose) - Self.heading(last))) * 180 / .pi
            guard move >= Self.keyDistance || turn >= Self.keyTurnDegrees || (t - lastKeyTime > Self.keyInterval && move > 0.3) else { return }
        }
        guard let snap = FrameSnapshot(frame: frame, maxSide: 384) else { return }
        lastKeyPose = pose
        lastKeyTime = t
        working = true
        let candidates = others
        Task.detached(priority: .utility) { [weak self] in
            let print = Self.featurePrint(snap.image)
            let live = VoxelIndex.downsample(snap.depthPoints(), size: 0.08)
            await self?.process(print: print, live: live, pose: pose, candidates: candidates)
        }
    }

    private func process(print: [Float]?, live: [simd_float3], pose: simd_float4x4, candidates: [MapPiece]) async {
        defer { working = false }
        guard let print else { return }
        current.keyframes.append(MapKeyframe(pose: pose, print: print))
        thinKeyframes()
        dirty = true
        guard !candidates.isEmpty, live.count >= 150 else { return }
        for c in FeaturePrint.candidates(for: print, in: candidates, limit: 2, maxDistance: Self.maxPrintDistance) {
            guard others.contains(where: { $0.id == c.piece }), let piece = candidates.first(where: { $0.id == c.piece }),
                  piece.points.count >= 900, piece.keyframes.indices.contains(c.keyframe) else { continue }
            let target = await target(for: piece)
            let seed = Self.seed(live: pose, stored: piece.keyframes[c.keyframe].pose)
            let fit = await Task.detached(priority: .utility) { PointRegistration.align(source: live, target: target, initial: seed) }.value
            guard let fit else { continue }
            onLog?(String(format: "map: view like piece %@ (%.2f): %.1f mm, %.0f%% matched, constraint %.2f%@", String(piece.id.uuidString.prefix(4)),
                          c.distance, fit.rms * 1000, fit.inlierRatio * 100, fit.constraint, fit.isMatch ? " ✓" : ""))
            if let link = consensus.add(piece: piece.id, fit: fit, camera: pose, time: CACurrentMediaTime()) {
                merge(piece, liveToPiece: link)
                return
            }
        }
    }

    private func target(for piece: MapPiece) async -> RegistrationTarget {
        if let t = targets[piece.id] { return t }
        let points = piece.surface
        let t = await Task.detached(priority: .utility) { RegistrationTarget(points: points) }.value
        targets[piece.id] = t
        return t
    }

    private func merge(_ piece: MapPiece, liveToPiece: simd_float4x4) {
        let pieceToLive = liveToPiece.inverse
        let moved = piece.transformed(by: pieceToLive)
        current.keyframes += moved.keyframes
        thinKeyframes()
        current.setSurface(VoxelIndex.downsample(current.surface + moved.surface, size: 0.04))
        others.removeAll { $0.id == piece.id }
        targets[piece.id] = nil
        consensus.forget(piece.id)
        merged.append(piece.id)
        dirty = true
        onLog?(String(format: "map: linked piece %@ (turn %.1f°, shift %.2f m)", String(piece.id.uuidString.prefix(4)),
                      PointRegistration.yaw(of: pieceToLive) * 180 / .pi, simd_length(pieceToLive.columns.3.xyz)))
        onLink?(piece, pieceToLive)
    }

    /// Saves this piece with the room surfaces ARKit has meshed so far; merged pieces are removed.
    func save(mesh: [simd_float3]) {
        guard enabled else { return }
        var surface = VoxelIndex.downsample(current.surface + mesh, size: 0.04)
        if surface.count > Self.maxSurfacePoints { surface = VoxelIndex.downsample(surface, size: 0.06) }
        current.setSurface(surface)
        current.updated = Date()
        MapStore.save(current)
        for id in merged { MapStore.remove(id) }
        merged = []
        dirty = false
    }

    /// Keeps at most `maxKeyframes`: the oldest of two views from nearly the same spot goes first.
    private func thinKeyframes() {
        while current.keyframes.count > Self.maxKeyframes {
            let ks = current.keyframes
            let redundant = ks.indices.first { i in
                ks.indices.contains { j in
                    j > i && simd_distance(ks[i].position, ks[j].position) < 0.5
                        && abs(Self.wrapped(Self.heading(ks[i].pose) - Self.heading(ks[j].pose))) < 0.5
                }
            }
            current.keyframes.remove(at: redundant ?? 0)
        }
    }

    // MARK: Geometry and fingerprints

    /// The start for fitting a live view onto a stored one that looked alike: the camera stood
    /// about where it stood then, and both worlds are upright, so only the headings differ.
    nonisolated static func seed(live: simd_float4x4, stored: simd_float4x4) -> simd_float4x4 {
        let yaw = heading(stored) - heading(live)
        let r = PointRegistration.transform(yaw: yaw, translation: .zero)
        let t = stored.columns.3.xyz - (r * simd_float4(live.columns.3.xyz, 1)).xyz
        return PointRegistration.transform(yaw: yaw, translation: t)
    }

    /// The direction the camera looks, as a turn about the vertical (radians).
    nonisolated static func heading(_ m: simd_float4x4) -> Float {
        let forward = -m.columns.2.xyz
        return atan2(forward.x, forward.z)
    }

    nonisolated static func wrapped(_ a: Float) -> Float {
        var d = a.truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return d
    }

    /// Apple Vision's image fingerprint (on the Neural Engine, a few milliseconds).
    nonisolated static func featurePrint(_ image: CGImage) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let obs = request.results?.first else { return nil }
        let count = obs.elementCount
        switch obs.elementType {
        case .float: return obs.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
        case .double: return obs.data.withUnsafeBytes { $0.bindMemory(to: Double.self).prefix(count).map(Float.init) }
        default: return nil
        }
    }
}

extension simd_float4 {
    var xyz: simd_float3 { simd_float3(x, y, z) }
}

extension FrameSnapshot {
    /// The LiDAR points of this frame in world space: every `step`-th depth pixel that LiDAR is
    /// sure of, up to `maxDepth` metres away.
    func depthPoints(step: Int = 4, maxDepth: Float = 4) -> [simd_float3] {
        guard let depth else { return [] }
        var out: [simd_float3] = []
        for y in stride(from: 0, to: depth.height, by: step) {
            for x in stride(from: 0, to: depth.width, by: step) {
                let u = (CGFloat(x) + 0.5) / CGFloat(depth.width), v = (CGFloat(y) + 0.5) / CGFloat(depth.height)
                guard let d = depth.value(u: u, v: v, minConfidence: 2), d < maxDepth else { continue }
                out.append(worldPoint(sensor: CGPoint(x: u * sensorSize.width, y: v * sensorSize.height), depth: d))
            }
        }
        return out
    }
}
