import ARKit
import PipCore
import QuartzCore
import RealityKit
import simd

/// Recognising the saved room at start, and moving this session's outlines along when its coordinates jump.
extension ARController {
    /// What brings a point from the coordinates `epoch` to today's; nil across a fresh start.
    func carry(from epoch: Int) -> simd_float4x4? {
        var t = matrix_identity_float4x4
        for e in stride(from: epoch + 1, through: coordinates, by: 1) {
            guard let jump = jumps[e] else { return nil }
            t = jump * t
        }
        return t
    }

    /// ARKit recognised the saved room and moved the room's coordinates by `jump` (the camera did
    /// not move in that instant: its pose before and after gives the jump); frames up to `before`
    /// were in the old coordinates. Done at once, in the same step: this session's outlines go
    /// along onto new anchors (their own, ARKit's correction of them included), EdgeTAM's and its
    /// shape too, and every earlier measurement, so re-measuring does not read the jump as drift.
    /// They are also measured again (`trackingRecovered`), as after any loss of tracking.
    func realign(by jump: simd_float4x4, before: TimeInterval) {
        coordinates += 1
        jumps[coordinates] = jump
        edgeTAM.coordinatesMoved(before: before)
        let shift = simd_length(simd_float3(jump.columns.3.x, jump.columns.3.y, jump.columns.3.z))
        let angle = acos(min(1, max(-1, (jump.columns.0.x + jump.columns.1.y + jump.columns.2.z - 1) / 2))) * 180 / .pi
        // Found in the visual memory meanwhile: already in these coordinates.
        let alreadyHere = inSavedRoomCoordinates
        inSavedRoomCoordinates = []
        let current = Dictionary((arView.session.currentFrame?.anchors ?? []).map { ($0.identifier, $0.transform) }, uniquingKeysWith: { a, _ in a })
        var moved = 0
        for (id, m) in marks where id < Self.placeMarkBase && !alreadyHere.contains(id) {
            // Where an anchored outline is now: ARKit's correction of its anchor, then the jump;
            // unless ARKit has carried the anchor into the new coordinates already in this frame.
            var full = jump * (targetCorrections[id] ?? m.correction)
            if let entry = anchors[id], let now = current[entry.anchor.identifier] {
                let expected = (jump * entry.origin).columns.3.xyz, origin = entry.origin.columns.3.xyz
                let correction = now * simd_inverse(entry.origin)
                full = simd_distance(now.columns.3.xyz, expected) < simd_distance(now.columns.3.xyz, origin) ? correction : jump * correction
            }
            if var track = tracks[id] {
                track.align(steerShape[id] != nil || lockSeen(id) ? jump : full)
                tracks[id] = track
            }
            // ARKit's image anchor carries a locked outline into the new coordinates itself.
            if lockSeen(id) { continue }
            if let shape = steerShape[id] {
                func move(_ p: simd_float3) -> simd_float3 { (jump * simd_float4(p, 1)).xyz }
                steerShape[id] = (shape.shown.map(move), shape.target.map(move))
                var steeredMark = AnchoredMark(id: id, world: [steerShape[id]!.shown])
                steeredMark.lead = m.lead
                marks[id] = steeredMark
                drawnHistory[id] = nil
            } else {
                var placed = m.transformed(by: full)
                placed.correction = matrix_identity_float4x4
                placed.glide = .zero
                placed.lead = .zero
                place(placed)
            }
            moved += 1
        }
        if !tracks.isEmpty { trackingRecovered = true }
        onLockLog?(String(format: "map: recognised; the room's coordinates moved %.0f cm and %.0f°; %d outlines moved along", shift * 100, angle, moved))
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            relocalisingSince = nil
            let wasFirstRelocalisation = awaitingFirstRelocalisation
            awaitingFirstRelocalisation = false
            recognitionExtended = 0
            // Recognised: the room's coordinates moved to the saved map's. This session's outlines
            // go along at once (see `realign`).
            if wasFirstRelocalisation, let before = lastRecognisingCamera {
                realign(by: camera.transform * simd_inverse(before), before: lastRecognisingTime)
            }
            if wasFirstRelocalisation { DispatchQueue.main.async { [weak self] in self?.onRecognised?() } }
            lastRecognisingCamera = nil
            // Back after being lost (not the first start): every object is checked again. Also
            // when the cues were shown again before ARKit had recognised the room.
            if trackingLost, !tracks.isEmpty { trackingRecovered = true }
            trackingLost = false
            trackingNormal = true
            // Locks made while the saved room was being recognised were held back until now.
            if wasFirstRelocalisation { DispatchQueue.main.async { [weak self] in self?.reconfigureImages() } }
        case .limited(.relocalizing):
            // Wait a while for ARKit to recognise the room; in another room it never will.
            let since = relocalisingSince ?? Date()
            relocalisingSince = since
            trackingNormal = false
            trackingLost = true
            let firstTry = awaitingFirstRelocalisation
            // Once per spell of recognising (ARKit may switch between limited states meanwhile).
            if checkScheduledFor != since {
                checkScheduledFor = since
                scheduleRecognitionCheck(since: since, firstTry: firstTry, after: firstTry ? recognitionWait : Self.relocaliseWait)
            }
            if firstTry {
                // Recognising a saved room at start: tracking runs, in the session's own
                // coordinates for now. This session's cues are drawn (remembered places wait until
                // the room is recognised, see renderNow).
                trackingNormal = true
                overlay.isHidden = false
                return
            }
        case .limited(.initializing):
            trackingNormal = false
            trackingLost = true
        case .limited, .notAvailable:
            // Fast motion or few features: keep drawing; the outlines may lag briefly.
            trackingNormal = true
        }
        overlay.isHidden = !trackingNormal
    }

    static let relocaliseWait: TimeInterval = 10

    /// At start with a saved room: ARKit often recognises it within a few seconds, sometimes only
    /// after the user looked around. Questions are answered meanwhile (the cues of this session are
    /// drawn and go along when the room is recognised, see `realign`); on 1 Nov the room of 17
    /// minutes before, in the same light, was given up after 6.7 s because the user spoke.
    static let firstRelocaliseWait: TimeInterval = 25

    /// For the next saved room, when the first was not it.
    static let nextRelocaliseWait: TimeInterval = 15

    /// Giving up wipes this session's outlines (a fresh start): while some are on screen it waits,
    /// up to this much longer in all.
    static let maxRecognitionExtension: TimeInterval = 60

    /// When the wait for a saved room is over: try another (or start fresh), unless this session's
    /// cues are on screen; then a while longer, since a fresh start would wipe them.
    func scheduleRecognitionCheck(since: Date, firstTry: Bool, after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.relocalisingSince == since else { return }
            if firstTry, self.awaitingFirstRelocalisation {
                if self.hasPointedMarks, self.recognitionExtended < Self.maxRecognitionExtension {
                    self.recognitionExtended += 15
                    self.onLockLog?("map: still recognising the room; cues are on screen, so a while longer")
                    self.scheduleRecognitionCheck(since: since, firstTry: true, after: 15)
                    return
                }
                // The saved room is not this one: another saved room, or start fresh.
                self.onRelocaliseGaveUp?()
                return
            }
            self.trackingNormal = true
            self.overlay.isHidden = false
        }
    }
}
