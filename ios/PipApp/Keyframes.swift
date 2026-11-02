import ARKit
import Foundation
import PipCore
import simd

/// Pip's visual memory: a snapshot whenever the camera sees something new, with where the phone
/// was and LiDAR depth, so "where did I leave my keys?" can be answered and pointed at later.
///
/// The last 30 minutes are kept in full. With the user's memory consent, older snapshots stay on
/// this iPhone for a week: the newest view of every spot (half a metre, one of eight directions),
/// which is what "where did I leave it" needs, and bounds the storage. Each snapshot belongs to a
/// map piece (a session); once that session is linked to a later one (SpaceLinker), its snapshots
/// can be pointed at again in the room.
@MainActor
final class Keyframes {
    struct Frame {
        let id: UUID
        let time: Date
        /// About 768 px on the long side.
        let width: Int
        let height: Int
        var cameraTransform: simd_float4x4
        /// The pose in the coordinates of the session that took it (`cameraTransform` is in this
        /// session's once that session is linked; see SpaceLinker).
        var storedPose: simd_float4x4
        /// The captured image's size and intrinsics (sensor orientation), as in FrameSnapshot.
        let sensorSize: CGSize
        let intrinsics: simd_float3x3
        /// Depth grid size (upright orientation): 96×128 for new snapshots.
        let depthW: Int
        let depthH: Int
        /// The map piece the pose is in.
        var piece: UUID?
        /// The pose is in this session's frame, so the snapshot can be pointed at in the room.
        var located: Bool
        fileprivate var jpegData: Data?
        fileprivate var depthData: [Float16]?

        func jpeg() -> Data? { jpegData ?? VisualMemoryStore.jpeg(id) }

        func depthGrid() -> [Float16]? { depthData ?? VisualMemoryStore.depth(id, count: depthW * depthH) }

        /// The depth at a pixel: the median of the known samples around it.
        func depth(atPixel p: CGPoint) -> Float? {
            guard let grid = depthGrid(), grid.count == depthW * depthH else { return nil }
            let dx = Int(p.x / CGFloat(width) * CGFloat(depthW)), dy = Int(p.y / CGFloat(height) * CGFloat(depthH))
            var samples: [Float] = []
            for y in max(0, dy - 1)...min(depthH - 1, max(0, dy + 1)) {
                for x in max(0, dx - 1)...min(depthW - 1, max(0, dx + 1)) {
                    let d = Float(grid[y * depthW + x])
                    if d > 0.05 { samples.append(d) }
                }
            }
            return samples.isEmpty ? nil : samples.sorted()[samples.count / 2]
        }

        /// The point at a pixel, in the coordinates of the session that took it: where its depth is
        /// trustworthy (five samples or more round it, within 5 cm of each other: not on a depth
        /// edge), as `pipeval links` measured it.
        func storedPoint(atPixel p: CGPoint, grid: [Float16]) -> simd_float3? {
            guard grid.count == depthW * depthH else { return nil }
            let dx = Int(p.x / CGFloat(width) * CGFloat(depthW)), dy = Int(p.y / CGFloat(height) * CGFloat(depthH))
            var samples: [Float] = []
            for y in max(0, dy - 1)...min(depthH - 1, max(0, dy + 1)) {
                for x in max(0, dx - 1)...min(depthW - 1, max(0, dx + 1)) { samples.append(Float(grid[y * depthW + x])) }
            }
            guard let d = TrustedDepth.of(samples) else { return nil }
            return worldPoint(atPixel: p, depth: d, pose: storedPose)
        }

        /// The world point at a pixel of the stored image, at a given depth. Same mapping as
        /// FrameSnapshot: upright pixel → sensor pixel → camera space → world.
        func worldPoint(atPixel p: CGPoint, depth d: Float) -> simd_float3 {
            worldPoint(atPixel: p, depth: d, pose: cameraTransform)
        }

        func worldPoint(atPixel p: CGPoint, depth d: Float, pose: simd_float4x4) -> simd_float3 {
            let s = sensorSize.width / CGFloat(height)
            let q = CGPoint(x: p.y * s, y: sensorSize.height - p.x * s)
            let fx = intrinsics[0][0], fy = intrinsics[1][1], cx = intrinsics[2][0], cy = intrinsics[2][1]
            let x = (Float(q.x) - cx) / fx * d
            let y = -(Float(q.y) - cy) / fy * d
            let w = pose * simd_float4(x, y, -d, 1)
            return simd_float3(w.x, w.y, w.z)
        }
    }

    static let recentFor: TimeInterval = 30 * 60
    static let keepFor: TimeInterval = 7 * 24 * 3600
    static let maxFrames = 3000
    nonisolated static let depthW = 96, depthH = 128

    /// Oldest first.
    private(set) var frames: [Frame] = []
    /// Keep snapshots beyond this session (the user's memory consent).
    var persist = false
    /// The map piece this session builds: new snapshots belong to it.
    var currentPiece: UUID?
    /// A snapshot was kept on storage (with the user's consent): SpaceLinker makes its whole-view
    /// token for the sessions after this one.
    var onKept: ((Frame) -> Void)?
    private var lastPose: simd_float4x4?
    private var lastTime: TimeInterval = 0
    private var indexDirty = false
    private var lastIndexSave = Date.distantPast
    private var kept = 0
    /// Bumped by `forgetAll`, so snapshots still being encoded are dropped.
    private var generation = 0
    /// The last purge: what was taken from `since` on was dropped when it ran (`at`). A snapshot of
    /// that time still being encoded then is dropped when it comes in.
    private var lastPurge: (since: Date, at: Date)?

    /// Loads the week's snapshots: each can be pointed at once its session is linked (`carry`).
    func load() {
        guard persist else { return }
        let stored = VisualMemoryStore.loadIndex()
        frames = stored.map { s in
            Frame(id: s.id, time: s.time, width: s.width, height: s.height, cameraTransform: ARController.matrix(s.pose), storedPose: ARController.matrix(s.pose),
                  sensorSize: CGSize(width: s.sensorWidth, height: s.sensorHeight), intrinsics: Self.matrix3(s.intrinsics),
                  depthW: s.depthW, depthH: s.depthH, piece: s.piece, located: false)
        }.sorted { $0.time < $1.time }
        prune()
    }

    /// Called for camera frames; keeps one when the view has changed enough and the frame passes
    /// the quality gate (settled tracking, steady, sharp, light enough).
    func consider(_ frame: ARFrame, gate: CaptureGate) {
        guard case .normal = frame.camera.trackingState else { return }
        let t = frame.timestamp
        guard t - lastTime > 0.5 else { return }
        if let last = lastPose {
            let move = simd_distance(simd_make_float3(last.columns.3), simd_make_float3(frame.camera.transform.columns.3))
            let a = simd_make_float3(last.columns.2), b = simd_make_float3(frame.camera.transform.columns.2)
            let turn = acos(max(-1, min(1, simd_dot(simd_normalize(a), simd_normalize(b)))))
            guard move > 0.25 || turn > 20 * .pi / 180 || t - lastTime > 10 else { return }
        }
        guard gate.accepts(frame) else { return }
        lastTime = t
        lastPose = frame.camera.transform
        guard let snap = FrameSnapshot(frame: frame, maxSide: 768) else { return }
        let id = UUID(), taken = Date()
        let generation = self.generation
        let piece = currentPiece
        // Encoding and depth sampling happen off the main thread; it is written once kept.
        Task.detached(priority: .utility) { [weak self] in
            guard let jpeg = SetOfMarks.jpeg(snap.image, quality: 0.6) else { return }
            let depth = Self.depthGrid(snap)
            let kept = Frame(id: id, time: taken, width: snap.image.width, height: snap.image.height, cameraTransform: snap.cameraTransform, storedPose: snap.cameraTransform,
                             sensorSize: snap.sensorSize, intrinsics: snap.intrinsics, depthW: Self.depthW, depthH: Self.depthH,
                             piece: piece, located: true, jpegData: jpeg, depthData: depth)
            await self?.keep(kept, generation: generation)
        }
    }

    private func keep(_ frame: Frame, generation: Int) {
        // Forgotten meanwhile: dropped. Written only if the user agrees now, not when it was taken.
        guard self.generation == generation else { return }
        // Taken just before tracking broke, and purged while it was being encoded.
        if let p = lastPurge, frame.time >= p.since, frame.time < p.at { return }
        if persist, let jpeg = frame.jpegData, let depth = frame.depthData { VisualMemoryStore.write(id: frame.id, jpeg: jpeg, depth: depth) }
        frames.append(frame)
        if persist { onKept?(frame) }
        indexDirty = persist
        kept += 1
        if kept % 40 == 0 { prune() }
        saveIndexIfDue()
    }

    /// Tracking broke or jumped: snapshots since `since` may carry a wrong pose.
    func purge(since: Date) {
        lastPurge = (since, Date())
        let dropped = frames.filter { $0.time >= since && $0.located }.map(\.id)
        guard !dropped.isEmpty else { return }
        frames.removeAll { dropped.contains($0.id) }
        if persist {
            VisualMemoryStore.remove(dropped)
            indexDirty = true
        }
    }

    /// Another session was linked to this one (SpaceLinker): its snapshots can be pointed at here,
    /// each at the pose `carry` gives it (nil: not near enough to its links yet). Returns how many.
    @discardableResult
    func carry(_ piece: UUID, by carry: (Frame) -> simd_float4x4?) -> Int {
        var n = 0
        for i in frames.indices where frames[i].piece == piece && frames[i].piece != currentPiece {
            guard let pose = carry(frames[i]) else { continue }
            frames[i].cameraTransform = pose
            frames[i].located = true
            n += 1
        }
        return n
    }

    /// Keeps the last 30 minutes in full and, for the week before, the newest view of each spot.
    func prune() {
        let now = Date()
        var out: [Frame] = []
        var seen = Set<String>()
        var removed: [UUID] = []
        for f in frames.reversed() {
            let age = now.timeIntervalSince(f.time)
            if age > Self.keepFor || (!persist && age > Self.recentFor) {
                removed.append(f.id)
                continue
            }
            if age > Self.recentFor {
                let p = f.storedPose.columns.3
                let forward = -simd_make_float3(f.storedPose.columns.2)
                let heading = Int(((atan2(forward.x, forward.z) + .pi) / (2 * .pi) * 8).rounded(.down)) % 8
                let key = "\(f.piece?.uuidString ?? "-")|\(Int((p.x / 0.5).rounded(.down)))|\(Int((p.z / 0.5).rounded(.down)))|\(heading)"
                guard seen.insert(key).inserted else {
                    removed.append(f.id)
                    continue
                }
            }
            var f = f
            // Older snapshots are read from storage when a search needs them.
            if persist, age > Self.recentFor { f.jpegData = nil; f.depthData = nil }
            out.append(f)
        }
        if out.count > Self.maxFrames {
            removed += out[Self.maxFrames...].map(\.id)
            out = Array(out.prefix(Self.maxFrames))
        }
        frames = out.reversed()
        if persist, !removed.isEmpty {
            VisualMemoryStore.remove(removed)
            indexDirty = true
        }
    }

    func saveIndexIfDue() {
        guard indexDirty, Date().timeIntervalSince(lastIndexSave) > 30 else { return }
        saveIndex()
    }

    func saveIndex() {
        guard persist, indexDirty else { return }
        let stored = frames.map { f in
            // The pose in its own session's coordinates, never the carried one.
            VisualMemoryStore.Stored(id: f.id, time: f.time, width: f.width, height: f.height, pose: ARController.values(f.storedPose),
                                     sensorWidth: Double(f.sensorSize.width), sensorHeight: Double(f.sensorSize.height),
                                     intrinsics: [f.intrinsics.columns.0, f.intrinsics.columns.1, f.intrinsics.columns.2].flatMap { [$0.x, $0.y, $0.z] },
                                     depthW: f.depthW, depthH: f.depthH, piece: f.piece)
        }
        VisualMemoryStore.saveIndex(stored)
        indexDirty = false
        lastIndexSave = Date()
    }

    /// Without consent: snapshots stay for this session only, and the stored ones go.
    func stopPersisting() {
        persist = false
        VisualMemoryStore.removeAll()
        prune()
    }

    func forgetAll() {
        frames = []
        lastPose = nil
        generation += 1
        VisualMemoryStore.removeAll()
    }

    nonisolated static func depthGrid(_ snap: FrameSnapshot) -> [Float16] {
        let w = snap.image.width, h = snap.image.height
        var depth = [Float16](repeating: 0, count: depthW * depthH)
        for y in 0..<depthH {
            for x in 0..<depthW {
                let p = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(depthW) * CGFloat(w), y: (CGFloat(y) + 0.5) / CGFloat(depthH) * CGFloat(h))
                depth[y * depthW + x] = Float16(snap.depth(atSensor: snap.sensorPoint(p), minConfidence: 1) ?? 0)
            }
        }
        return depth
    }

    nonisolated static func matrix3(_ v: [Float]) -> simd_float3x3 {
        guard v.count == 9 else { return matrix_identity_float3x3 }
        return simd_float3x3(columns: (simd_float3(v[0], v[1], v[2]), simd_float3(v[3], v[4], v[5]), simd_float3(v[6], v[7], v[8])))
    }
}

/// Where the visual memory lives on this iPhone: a JPEG, a depth grid and a whole-view token per
/// snapshot, and one index, in Documents/memory/frames. Only written with the user's consent.
enum VisualMemoryStore {
    struct Stored: Codable {
        var id: UUID
        var time: Date
        var width: Int
        var height: Int
        var pose: [Float]
        var sensorWidth: Double
        var sensorHeight: Double
        var intrinsics: [Float]
        var depthW: Int
        var depthH: Int
        var piece: UUID?
    }

    static var dir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("memory/frames")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// All file work in order, on one queue: a removal comes after every write queued before it.
    private static let io = DispatchQueue(label: "pip.visualmemory", qos: .utility)

    static func loadIndex() -> [Stored] {
        io.sync {
            let url = dir.appendingPathComponent("index.json")
            guard let data = try? Data(contentsOf: url) else { return [] }
            guard let stored = try? JSONDecoder().decode([Stored].self, from: data) else {
                // Not what Pip writes: kept aside, never overwritten.
                try? FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("index.unreadable-\(Int(Date().timeIntervalSince1970)).json"))
                return []
            }
            // Snapshots without an entry (the app ended before the index was saved) can never be
            // used: they go, once they are an hour old. Whole-view tokens of another model go at once.
            let known = Set(stored.map(\.id.uuidString))
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where ["jpg", "depth", "whole", "corners"].contains(file.pathExtension) {
                let id = String(file.lastPathComponent.prefix { $0 != "." })
                if file.pathExtension == "whole" || file.pathExtension == "corners", known.contains(id),
                   file.lastPathComponent != wholeName(id), file.lastPathComponent != cornersName(id) {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                guard !known.contains(id) else { continue }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if Date().timeIntervalSince(modified) > 3600 { try? FileManager.default.removeItem(at: file) }
            }
            return stored
        }
    }

    static func saveIndex(_ stored: [Stored]) {
        io.async {
            let url = dir.appendingPathComponent("index.json")
            if let data = try? JSONEncoder().encode(stored) { try? data.write(to: url, options: [.atomic, .completeFileProtection]) }
        }
    }

    static func write(id: UUID, jpeg: Data, depth: [Float16]) {
        io.async {
            let d = dir
            try? jpeg.write(to: d.appendingPathComponent("\(id.uuidString).jpg"), options: [.atomic, .completeFileProtection])
            let raw = depth.withUnsafeBufferPointer { Data(buffer: $0) }
            try? raw.write(to: d.appendingPathComponent("\(id.uuidString).depth"), options: [.atomic, .completeFileProtection])
        }
    }

    static func jpeg(_ id: UUID) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent("\(id.uuidString).jpg"))
    }

    static func depth(_ id: UUID, count: Int) -> [Float16]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(id.uuidString).depth")), data.count == count * 2 else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
    }

    static func remove(_ ids: [UUID]) {
        io.async {
            let d = dir
            for id in ids {
                try? FileManager.default.removeItem(at: d.appendingPathComponent("\(id.uuidString).jpg"))
                try? FileManager.default.removeItem(at: d.appendingPathComponent("\(id.uuidString).depth"))
                try? FileManager.default.removeItem(at: d.appendingPathComponent(wholeName(id.uuidString)))
                try? FileManager.default.removeItem(at: d.appendingPathComponent(cornersName(id.uuidString)))
            }
        }
    }

    /// A snapshot's DINOv2 whole-view token (ViewFeatures: which stored views show the same place),
    /// kept beside it, so it is made once. Made again at every start, one per 0.25 s, the newest
    /// snapshots first, an earlier session's bathroom views were there only 30 s in, as the user
    /// left the bathroom (2 Nov, 18:36). Named after the model, whose tokens alone are read.
    static func wholeName(_ id: String) -> String { "\(id).\(ViewFeatures.tag).whole" }

    static func whole(_ id: UUID) -> [Float]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(wholeName(id.uuidString))), data.count == ViewFeatures.dim * 2 else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }.map(Float.init)
    }

    /// A snapshot's described corners (lifted in its own session's room) and its fingerprint, kept
    /// beside it: described again at every start, 82 ms a snapshot, a home's 400 took 30-50 s, and
    /// the corners could link only the ones done (2 Nov).
    static func cornersName(_ id: String) -> String { "\(id).\(ViewPoints.cacheTag).corners" }

    static func corners(_ id: UUID) -> (points: ViewPoints, print: ViewPrint?)? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(cornersName(id.uuidString))), data.count > 4 else { return nil }
        let length = Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard data.count >= 4 + length, let points = ViewPoints(encoded: data.subdata(in: 4..<(4 + length))) else { return nil }
        let rest = data.subdata(in: (4 + length)..<data.count)
        return (points, rest.isEmpty ? nil : ViewPrint(archived: rest))
    }

    static func writeCorners(_ id: UUID, _ points: ViewPoints, _ print: ViewPrint?) {
        let encoded = points.encoded
        var data = Data()
        withUnsafeBytes(of: UInt32(encoded.count)) { data.append(contentsOf: $0) }
        data.append(encoded)
        if let archived = print?.archived { data.append(archived) }
        io.async {
            let d = dir
            guard FileManager.default.fileExists(atPath: d.appendingPathComponent("\(id.uuidString).jpg").path) else { return }
            try? data.write(to: d.appendingPathComponent(cornersName(id.uuidString)), options: [.atomic, .completeFileProtection])
        }
    }

    /// Written only beside a snapshot that is still kept (one removed meanwhile gets none).
    static func writeWhole(_ id: UUID, _ whole: [Float]) {
        guard whole.count == ViewFeatures.dim else { return }
        io.async {
            let d = dir
            guard FileManager.default.fileExists(atPath: d.appendingPathComponent("\(id.uuidString).jpg").path) else { return }
            let raw = whole.map { Float16($0) }.withUnsafeBufferPointer { Data(buffer: $0) }
            try? raw.write(to: d.appendingPathComponent(wholeName(id.uuidString)), options: [.atomic, .completeFileProtection])
        }
    }

    static func removeAll() {
        io.async { _ = try? FileManager.default.removeItem(at: dir) }
    }
}
