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

    /// A piece was linked: the piece, the fine fit (stored frame ← live frame) with its
    /// uncertainty, and the transform from the piece's frame into this session's.
    var onLink: ((MapPiece, MapLinker.Refined, simd_float4x4) -> Void)?
    var onLog: ((String) -> Void)?
    /// The live LiDAR mesh around a point (this session's frame): fused over many frames, so far
    /// better for fitting than one depth frame.
    var meshNear: ((simd_float3, Float) -> [simd_float3])?

    /// A keyframe when the phone moved this far, turned this much, or after this long.
    static let keyDistance: Float = 0.75
    static let keyTurnDegrees: Float = 25
    static let keyInterval: TimeInterval = 10
    static let maxKeyframes = 400
    /// The fingerprint only proposes: the three most alike stored views are always tried, and
    /// the 3D fit decides.
    static let candidatesPerKeyframe = 3
    static let maxSurfacePoints = 250_000

    /// `piece`: the stored piece ARKit is relocalising into (its frame becomes this session's).
    func begin(continuing piece: MapPiece?, others: [MapPiece]) {
        current = piece ?? MapPiece()
        self.others = others
        references = [:]
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
            guard move >= Self.keyDistance || turn >= Self.keyTurnDegrees || (t - lastKeyTime > Self.keyInterval && move > 0.3) else {
                recheck(at: pose, now: t)
                return
            }
        }
        guard let snap = FrameSnapshot(frame: frame, maxSide: 384) else { return }
        lastKeyPose = pose
        lastKeyTime = t
        working = true
        let candidates = others
        // The live mesh around the user when ARKit has built enough of it, else this depth frame.
        let mesh = candidates.isEmpty ? [] : (meshNear?(pose.columns.3.xyz, 3.5) ?? [])
        Task.detached(priority: .utility) { [weak self] in
            let print = Self.featurePrint(snap.image)
            let live = mesh.count >= 2000 ? mesh : snap.depthPoints()
            await self?.process(print: print, live: live, pose: pose, candidates: candidates)
        }
    }

    private func process(print: [Float]?, live dense: [simd_float3], pose: simd_float4x4, candidates: [MapPiece]) async {
        defer { working = false }
        guard let print else { return }
        current.keyframes.append(MapKeyframe(pose: pose, print: print))
        thinKeyframes()
        dirty = true
        let live = VoxelIndex.downsample(dense, size: 0.08)
        guard !candidates.isEmpty, live.count >= 150 else { return }
        for c in FeaturePrint.candidates(for: print, in: candidates, limit: Self.candidatesPerKeyframe, maxDistance: .infinity) {
            guard others.contains(where: { $0.id == c.piece }), let piece = candidates.first(where: { $0.id == c.piece }),
                  piece.points.count >= 900, piece.keyframes.indices.contains(c.keyframe) else { continue }
            let target = await target(for: piece)
            let stored = piece.keyframes[c.keyframe].pose
            // Fifteen starts around that view (the user may stand elsewhere and look aside), the
            // two most promising fitted in full, the best kept.
            let fit = await Task.detached(priority: .utility) { () -> PointRegistration.Result? in
                let starts = MapLinker.bestSeeds(MapLinker.seeds(live: pose, stored: stored), source: live, target: target, keep: 2)
                return starts.compactMap { PointRegistration.align(source: live, target: target, initial: $0) }
                    .max { ($0.isMatch ? 1 : 0, $0.inlierRatio) < ($1.isMatch ? 1 : 0, $1.inlierRatio) }
            }.value
            guard let fit else { continue }
            onLog?(String(format: "map: view like piece %@ (%.2f): %.1f mm, %.0f%% matched, constraint %.2f%@", String(piece.id.uuidString.prefix(4)),
                          c.distance, fit.rms * 1000, fit.inlierRatio * 100, fit.constraint, fit.isMatch ? " ✓" : ""))
            if let link = consensus.add(piece: piece.id, fit: fit, camera: pose, time: CACurrentMediaTime()) {
                // The same place, unambiguously: now the fine fit over all the live mesh around the user.
                let around = meshNear?(pose.columns.3.xyz, 5) ?? dense
                let source = VoxelIndex.downsample(around.count >= 2000 ? around : dense, size: 0.04)
                let refined = await Task.detached(priority: .utility) { MapLinker.refine(source: source, target: target, initial: link) }.value
                guard let refined, refined.inlierRatio > 0.5 else {
                    onLog?("map: fine fit failed; waiting for more of the room")
                    consensus.forget(piece.id)
                    continue
                }
                merge(piece, refined: refined)
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

    private func merge(_ piece: MapPiece, refined: MapLinker.Refined) {
        let pieceToLive = refined.transform.inverse
        let moved = piece.transformed(by: pieceToLive)
        // Kept as a reference, so this session's drift against it can be measured and corrected.
        let surface = moved.surface
        Task.detached(priority: .utility) { [weak self] in
            let target = RegistrationTarget(points: surface)
            await self?.addReference(piece.id, target)
        }
        current.keyframes += moved.keyframes
        thinKeyframes()
        current.setSurface(VoxelIndex.downsample(current.surface + moved.surface, size: 0.04))
        others.removeAll { $0.id == piece.id }
        targets[piece.id] = nil
        consensus.forget(piece.id)
        merged.append(piece.id)
        dirty = true
        onLog?(String(format: "map: linked piece %@ (turn %.2f°, shift %.3f m, %d points, ±%.1f mm at the overlap)", String(piece.id.uuidString.prefix(4)),
                      PointRegistration.yaw(of: pieceToLive) * 180 / .pi, simd_length(pieceToLive.columns.3.xyz), refined.matched,
                      refined.uncertainty(at: refined.centre) * 1000))
        onLink?(piece, refined, pieceToLive)
    }

    // MARK: Staying aligned (like a VPS's background relocalisation)

    /// A linked piece's surfaces, in this session's frame as they were linked, and how this
    /// session has drifted against them since.
    private struct Reference {
        let target: RegistrationTarget
        /// Where the linked surfaces are now in this session's frame: linking-time frame → live
        /// frame now (identity until drift shows).
        var drift = matrix_identity_float4x4
    }
    private var references: [UUID: Reference] = [:]
    private var lastRecheck: TimeInterval = 0
    static let recheckInterval: TimeInterval = 30

    /// This session drifted against a linked piece: move its places by `delta` (live frame).
    var onDrift: ((UUID, simd_float4x4) -> Void)?

    private func addReference(_ id: UUID, _ target: RegistrationTarget) {
        references[id] = Reference(target: target)
    }

    /// Every half minute in a linked room: lay the live mesh around the user onto the linked
    /// piece again. A firm fit that differs from before is drift; the piece's places follow it.
    func recheck(at pose: simd_float4x4, now: TimeInterval) {
        guard enabled, !working, !references.isEmpty, now - lastRecheck >= Self.recheckInterval,
              let mesh = meshNear?(pose.columns.3.xyz, 3.5), mesh.count >= 2000 else { return }
        lastRecheck = now
        working = true
        let refs = references
        Task.detached(priority: .utility) { [weak self] in
            var results: [(UUID, MapLinker.Refined)] = []
            for (id, ref) in refs {
                if let r = MapLinker.refine(source: mesh, target: ref.target, initial: ref.drift.inverse), r.inlierRatio > 0.5 { results.append((id, r)) }
            }
            await self?.applyRecheck(results)
        }
    }

    private func applyRecheck(_ results: [(UUID, MapLinker.Refined)]) {
        defer { working = false }
        for (id, r) in results {
            guard var ref = references[id] else { continue }
            let firm = r.constraint >= PointRegistration.minConstraint && r.uncertainty(at: r.centre) < 0.01
            let drift = r.transform.inverse
            let delta = drift * ref.drift.inverse
            let shift = simd_length(delta.columns.3.xyz), turn = abs(PointRegistration.yaw(of: delta)) * 180 / .pi
            onLog?(String(format: "map: recheck piece %@: drift %.1f cm, %.2f°%@", String(id.uuidString.prefix(4)),
                          simd_length(drift.columns.3.xyz) * 100, PointRegistration.yaw(of: drift) * 180 / .pi, firm ? "" : " (not firm, ignored)"))
            // Under half a centimetre is noise; over 30 cm or 3° is not drift but a wrong fit.
            guard firm, shift > 0.005 || turn > 0.1, shift < 0.3, turn < 3 else { continue }
            ref.drift = drift
            references[id] = ref
            onDrift?(id, delta)
        }
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

    nonisolated static func heading(_ m: simd_float4x4) -> Float { MapLinker.heading(m) }

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
