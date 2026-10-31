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
    /// Spots and directions this piece has keyframes for (0.5 m, eight headings, three pitches).
    private var coverage = Set<SIMD4<Int32>>()
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
    static let maxSurfacePoints = 400_000

    /// `piece`: the stored piece ARKit is relocalising into (its frame becomes this session's).
    func begin(continuing piece: MapPiece?, others: [MapPiece]) {
        current = piece ?? MapPiece()
        coverage = Set(current.keyframes.map { Self.bin($0.pose) })
        self.others = others
        references = [:]
        pendingSurfaces = []
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
        coverage = []
        lastKeyPose = nil
        dirty = false
    }

    /// Tracking broke or jumped: keyframes since `since` may carry a wrong pose.
    func purge(since: Date) {
        let before = current.keyframes.count
        current.keyframes.removeAll { $0.time >= since }
        if current.keyframes.count != before {
            coverage = Set(current.keyframes.map { Self.bin($0.pose) })
            onLog?("map: dropped \(before - current.keyframes.count) keyframes around a tracking break")
        }
    }

    nonisolated static func bin(_ pose: simd_float4x4) -> SIMD4<Int32> {
        let p = pose.columns.3
        let forward = -pose.columns.2.xyz
        let heading = Int32(((atan2(forward.x, forward.z) + .pi) / (2 * .pi) * 8).rounded(.down)) % 8
        let pitch = asin(max(-1, min(1, forward.y)))
        let band: Int32 = pitch < -.pi / 12 ? 0 : (pitch > .pi / 12 ? 2 : 1)
        return SIMD4(Int32((p.x / 0.5).rounded(.down)), Int32((p.z / 0.5).rounded(.down)), heading, band)
    }

    func consider(_ frame: ARFrame, gate: CaptureGate) {
        guard enabled, !working, case .normal = frame.camera.trackingState else { return }
        let t = frame.timestamp
        let pose = frame.camera.transform
        // A view from a spot or direction this piece has no keyframe for yet counts at once, so
        // the piece can be recognised from every side.
        let uncovered = !coverage.contains(Self.bin(pose)) && t - lastKeyTime > 1
        if let last = lastKeyPose, !uncovered {
            let move = simd_distance(last.columns.3.xyz, pose.columns.3.xyz)
            let turn = abs(Self.wrapped(Self.heading(pose) - Self.heading(last))) * 180 / .pi
            guard move >= Self.keyDistance || turn >= Self.keyTurnDegrees || (t - lastKeyTime > Self.keyInterval && move > 0.3) else {
                recheck(at: pose, now: t)
                return
            }
        }
        // Only sharp, steady, well-lit frames with settled tracking go into the map.
        guard gate.accepts(frame), let snap = FrameSnapshot(frame: frame, maxSide: 384) else { return }
        coverage.insert(Self.bin(pose))
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
        let t = await Task.detached(priority: .utility) { piece.registrationTarget() }.value
        targets[piece.id] = t
        return t
    }

    private func merge(_ piece: MapPiece, refined: MapLinker.Refined) {
        let pieceToLive = refined.transform.inverse
        let moved = piece.transformed(by: pieceToLive)
        // Kept as a reference, so this session's drift against it can be measured and corrected.
        Task.detached(priority: .utility) { [weak self] in
            let target = moved.registrationTarget()
            await self?.addReference(piece.id, target)
        }
        current.keyframes += moved.keyframes
        thinKeyframes()
        // Its surfaces join this piece's at the next save, averaged off the main thread.
        pendingSurfaces.append((moved.surface, moved.surfaceNormals, moved.classes))
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
        /// A correction one recheck proposed, waiting for a second from elsewhere to agree: one
        /// fit alone (a mirror, a repeated wall) never moves the places.
        var proposal: (drift: simd_float4x4, camera: simd_float4x4, time: TimeInterval)?
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
            await self?.applyRecheck(results, camera: pose, now: now)
        }
    }

    private func applyRecheck(_ results: [(UUID, MapLinker.Refined)], camera: simd_float4x4, now: TimeInterval) {
        defer { working = false }
        for (id, r) in results {
            guard var ref = references[id] else { continue }
            let firm = r.constraint >= PointRegistration.minConstraint && r.uncertainty(at: r.centre) < 0.01
            let drift = r.transform.inverse
            let delta = drift * ref.drift.inverse
            let shift = simd_length(delta.columns.3.xyz), turn = abs(PointRegistration.yaw(of: delta)) * 180 / .pi
            onLog?(String(format: "map: recheck piece %@: %.1f cm, %.2f° from the current link%@", String(id.uuidString.prefix(4)),
                          shift * 100, turn, firm ? "" : " (not firm, ignored)"))
            // Under half a centimetre is noise (and confirms the link); over 30 cm or 3° is not
            // drift but a wrong fit.
            guard firm, shift < 0.3, turn < 3 else { continue }
            guard shift > 0.005 || turn > 0.1 else {
                ref.proposal = nil
                references[id] = ref
                continue
            }
            // A second recheck from at least half a metre or 20° away must agree within 1 cm and
            // 0.3° before the places move.
            if let p = ref.proposal, now - p.time < 120 {
                let apart = simd_distance(p.camera.columns.3, camera.columns.3) >= 0.5
                    || abs(Self.wrapped(Self.heading(p.camera) - Self.heading(camera))) * 180 / .pi >= 20
                let between = drift * p.drift.inverse
                let agree = simd_length(between.columns.3.xyz) < 0.01 && abs(PointRegistration.yaw(of: between)) * 180 / .pi < 0.3
                if agree, apart {
                    ref.drift = drift
                    ref.proposal = nil
                    references[id] = ref
                    onLog?(String(format: "map: drift of %.1f cm confirmed from two views; places follow", shift * 100))
                    onDrift?(id, delta)
                    continue
                }
                if agree { continue } // same view again: wait for one from elsewhere
            }
            ref.proposal = (drift, camera, now)
            references[id] = ref
        }
    }

    /// Surfaces of linked pieces, waiting to be averaged into this piece at the next save.
    private var pendingSurfaces: [(points: [simd_float3], normals: [simd_float3]?, classes: [UInt8]?)] = []
    private var saving = false

    /// Saves this piece with the room surfaces ARKit has meshed so far (raw mesh vertices; they
    /// are averaged and written off the main thread); merged pieces are removed. `done` runs once
    /// the files are written.
    func save(mesh: (points: [simd_float3], normals: [simd_float3], classes: [UInt8]), done: @escaping () -> Void = {}) {
        guard enabled, !saving else { done(); return }
        saving = true
        var piece = current
        let removed = merged
        let limit = Self.maxSurfacePoints
        let pending = pendingSurfaces
        pendingSurfaces = []
        Task.detached(priority: .userInitiated) { [weak self] in
            for p in pending { piece.addSurface(p.points, normals: p.normals, classes: p.classes, limit: limit) }
            piece.addSurface(mesh.points, normals: mesh.normals, classes: mesh.classes, limit: limit)
            piece.updated = Date()
            MapStore.save(piece)
            for id in removed { MapStore.remove(id) }
            await self?.saved(piece, removed: removed)
            done()
        }
    }

    private func saved(_ piece: MapPiece, removed: [UUID]) {
        saving = false
        guard piece.id == current.id else { return }
        // Keyframes added meanwhile stay; the surfaces are the averaged ones just written.
        current.setSurface(piece.surface, normals: piece.surfaceNormals, classes: piece.classes)
        current.updated = piece.updated
        merged.removeAll { removed.contains($0) }
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
