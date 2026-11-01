import ARKit
import Foundation
import PipCore
import simd

/// Pip's map of the user's home, built while Pip is used, never scanned on purpose.
///
/// Every session keeps a map piece in its own frame: where the camera stood, every metre or so
/// (map keyframes), with where on earth and in what light it was made. ARKit's world map of the
/// same session is stored next to it (MapStore); a later session that ARKit recognises in it
/// continues that piece. Places remembered in another piece of the same room are anchored again
/// when they are found here (GuideModel.adoptPlacesOfThisRoom).
@MainActor
final class MapKeeper {
    /// The piece this session builds; its frame is this session's frame.
    private(set) var current = MapPiece()
    /// Pieces from earlier sessions, other than this one.
    private(set) var others: [MapPiece] = []
    private var lastKeyPose: simd_float4x4?
    private var lastKeyTime: TimeInterval = 0
    /// Spots and directions this piece has keyframes for (0.5 m, eight headings, three pitches).
    private var coverage = Set<SIMD4<Int32>>()
    /// Something changed since the last save.
    private(set) var dirty = false
    /// Only with the user's consent: without it nothing is kept beyond the session anyway.
    var enabled = false

    var onLog: ((String) -> Void)?

    /// A keyframe when the phone moved this far, turned this much, or after this long.
    static let keyDistance: Float = 0.75
    static let keyTurnDegrees: Float = 25
    static let keyInterval: TimeInterval = 10
    static let maxKeyframes = 400

    /// `piece`: the stored piece ARKit is relocalising into (its frame becomes this session's).
    func begin(continuing piece: MapPiece?, others: [MapPiece]) {
        current = piece ?? MapPiece()
        coverage = Set(current.keyframes.map { Self.bin($0.pose) })
        self.others = others
        lastKeyPose = nil
        dirty = false
    }

    /// ARKit did not recognise the room of the piece it tried: that piece stays one of the
    /// others, and this session starts a piece of its own.
    func startNewPiece() {
        if !current.keyframes.isEmpty { others.append(current) }
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
        guard enabled, case .normal = frame.camera.trackingState else { return }
        let t = frame.timestamp
        let pose = frame.camera.transform
        // A view from a spot or direction this piece has no keyframe for yet counts at once.
        let uncovered = !coverage.contains(Self.bin(pose)) && t - lastKeyTime > 1
        if let last = lastKeyPose, !uncovered {
            let move = simd_distance(last.columns.3.xyz, pose.columns.3.xyz)
            let turn = abs(Self.wrapped(Self.heading(pose) - Self.heading(last))) * 180 / .pi
            guard move >= Self.keyDistance || turn >= Self.keyTurnDegrees || (t - lastKeyTime > Self.keyInterval && move > 0.3) else { return }
        }
        // Only sharp, steady, well-lit frames with settled tracking.
        guard gate.accepts(frame) else { return }
        coverage.insert(Self.bin(pose))
        lastKeyPose = pose
        lastKeyTime = t
        current.keyframes.append(MapKeyframe(pose: pose))
        thinKeyframes()
        dirty = true
    }

    private var saving = false

    /// The light the room is mapped in now (kept with the piece, see MapLight).
    func setLight(_ light: MapLight) {
        current.light = light
    }

    /// Where on earth this piece is being mapped (kept with it when it is saved): a better fix
    /// replaces a worse one.
    func setLocation(_ point: GeoPoint) {
        if let old = current.location, old.accuracy <= point.accuracy, old.couldBeSamePlace(as: point) { return }
        current.location = point
    }

    /// Saves this piece; `done` runs once the file is written.
    func save(done: @escaping () -> Void = {}) {
        guard enabled, !saving else { done(); return }
        saving = true
        var piece = current
        piece.updated = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            MapStore.save(piece)
            await self?.saved(piece)
            done()
        }
    }

    private func saved(_ piece: MapPiece) {
        saving = false
        guard piece.id == current.id else { return }
        current.updated = piece.updated
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

    // MARK: Geometry

    /// The direction a camera looks, as a turn about the vertical (radians; it looks down −Z).
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
}

extension simd_float4 {
    var xyz: simd_float3 { simd_float3(x, y, z) }
}
