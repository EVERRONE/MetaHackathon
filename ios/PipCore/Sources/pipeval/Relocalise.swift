import CoreGraphics
import Foundation
import ImageIO
import PipCore
import simd

// pipeval relocalise <memory/frames folder> <piece A prefix> <piece B prefix>
//   Every pair of snapshots of two sessions: the view links (SessionLink.link) and whether they
//   make a session link (SessionLink.consensus).
// pipeval links <memory/frames folder> [--pieces A,B,C]
//   Every pair of sessions: the session link, if any, how many views agree and what conflicts; then
//   every triangle of linked sessions: A→B→C against A→C (the drift and errors a chain adds).

struct StoredFrame: Decodable {
    var id: String
    var time: Double
    var width: Int
    var height: Int
    var sensorWidth: Double
    var sensorHeight: Double
    var intrinsics: [Float]
    var pose: [Float]
    var piece: String?
    var depthW: Int
    var depthH: Int

    var transform: simd_float4x4 {
        simd_float4x4(columns: (SIMD4(pose[0], pose[1], pose[2], pose[3]), SIMD4(pose[4], pose[5], pose[6], pose[7]),
                                SIMD4(pose[8], pose[9], pose[10], pose[11]), SIMD4(pose[12], pose[13], pose[14], pose[15])))
    }

    /// A stored pixel (upright) at a depth, in the session's room coordinates (as Keyframes.Frame).
    func world(_ p: SIMD2<Float>, depth d: Float) -> SIMD3<Float> {
        let s = Float(sensorWidth) / Float(height)
        let qx = p.y * s, qy = Float(sensorHeight) - p.x * s
        let fx = intrinsics[0], fy = intrinsics[4], cx = intrinsics[6], cy = intrinsics[7]
        let x = (qx - cx) / fx * d, y = -(qy - cy) / fy * d
        let w = transform * SIMD4(x, y, -d, 1)
        return SIMD3(w.x, w.y, w.z)
    }
}

struct StoredView {
    var frame: StoredFrame
    var points: ViewPoints
}

/// The stored snapshots and their described corners lifted to their sessions' rooms.
func loadViews(_ dir: URL, pieces: Set<String>? = nil) -> [StoredView] {
    guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent("index.json").path),
          let all = try? JSONDecoder().decode([StoredFrame].self, from: data) else { fail("cannot read index.json") }
    let wanted = all.filter { f in pieces.map { set in set.contains { f.piece?.hasPrefix($0) == true } } ?? (f.piece != nil) }
    return wanted.compactMap { f -> StoredView? in
        guard let jpeg = FileManager.default.contents(atPath: dir.appendingPathComponent("\(f.id).jpg").path),
              let image = SetOfMarks.load(jpeg, maxSide: 4096), let grey = GrayImage(image),
              let raw = FileManager.default.contents(atPath: dir.appendingPathComponent("\(f.id).depth").path),
              raw.count == f.depthW * f.depthH * 2 else { return nil }
        let depth = raw.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }.map { Float($0) }
        func lift(_ p: SIMD2<Float>) -> SIMD3<Float>? {
            let dx = Int(p.x / Float(f.width) * Float(f.depthW)), dy = Int(p.y / Float(f.height) * Float(f.depthH))
            var s: [Float] = []
            for y in max(0, dy - 1)...min(f.depthH - 1, dy + 1) {
                for x in max(0, dx - 1)...min(f.depthW - 1, dx + 1) {
                    let d = depth[y * f.depthW + x]
                    if d > 0.1, d < 6 { s.append(d) }
                }
            }
            // Fewer than five samples, or on a depth edge (spread over 5 cm): not trusted.
            guard s.count >= 5 else { return nil }
            s.sort()
            guard s.last! - s.first! < 0.05 else { return nil }
            return f.world(p, depth: s[s.count / 2])
        }
        return StoredView(frame: f, points: ViewPoints(image: grey, lift: lift))
    }
}

func pieceName(_ v: StoredView) -> String { String((v.frame.piece ?? "????").prefix(4)) }

/// Every view link from the snapshots of session A to those of session B.
func viewLinks(_ a: [StoredView], _ b: [StoredView], settings: SessionLink.Settings) -> [ViewLink] {
    var out: [ViewLink] = []
    for (ib, vb) in b.enumerated() {
        for (ia, va) in a.enumerated() {
            if let l = SessionLink.link(va.points, vb.points, from: ia, to: ib, settings: settings) { out.append(l) }
        }
    }
    return out
}

func relocalise(_ args: [String]) {
    guard args.count >= 4 else { fail("pipeval relocalise <memory/frames> <piece A> <piece B>") }
    let dir = URL(fileURLWithPath: args[1])
    let views = loadViews(dir, pieces: [args[2], args[3]])
    let a = views.filter { pieceName($0).hasPrefix(args[2]) }, b = views.filter { pieceName($0).hasPrefix(args[3]) }
    print("piece A \(args[2]): \(a.count) snapshots; piece B \(args[3]): \(b.count)")
    let links = viewLinks(a, b, settings: SessionLink.Settings())
    for l in links.sorted(by: { $0.inliers > $1.inliers }).prefix(30) {
        print(String(format: "A%03d ↔ B%03d: %3d agree (median %.1f cm, spread %.0f cm): %@", l.from, l.to, l.inliers, l.residual * 100, l.spread * 100, l.transform.description))
    }
    if let group = SessionLink.consensus(links) {
        print("session link: \(Set(group.map(\.to)).count) views agree, \(group.reduce(0) { $0 + $1.inliers }) matches; \(links.count - group.count) view links disagree")
    } else {
        print("no session link (\(links.count) view links)")
    }
}

func linksAll(_ args: [String]) {
    guard args.count >= 2 else { fail("pipeval links <memory/frames> [--pieces A,B,C]") }
    let dir = URL(fileURLWithPath: args[1])
    let only = args.firstIndex(of: "--pieces").map { Set(args[$0 + 1].split(separator: ",").map(String.init)) }
    let t0 = Date()
    let views = loadViews(dir, pieces: only)
    let byPiece = Dictionary(grouping: views, by: pieceName)
    let names = byPiece.keys.filter { (byPiece[$0]?.count ?? 0) >= 3 }.sorted()
    print(String(format: "%d snapshots of %d sessions described in %.1f s", views.count, names.count, Date().timeIntervalSince(t0)))
    let settings = SessionLink.Settings()
    struct Linked { var group: [ViewLink]; var all: [ViewLink] }
    var linked: [String: Linked] = [:]
    for (i, a) in names.enumerated() {
        for b in names[(i + 1)...] {
            let links = viewLinks(byPiece[a]!, byPiece[b]!, settings: settings)
            guard !links.isEmpty else { continue }
            if let group = SessionLink.consensus(links, settings: settings) {
                let usable = SessionLink.usable(links, core: group, settings: settings)
                let rejected = links.filter { l in !usable.contains(l) }
                linked["\(a)→\(b)"] = Linked(group: usable, all: links)
                let mean = group.max { $0.inliers < $1.inliers }!.transform
                print(String(format: "%@ → %@: LINKED by %d views (%d matches), e.g. %@; %d more within drift; %d rejected (the strongest %d matches)",
                             a, b, Set(group.map(\.to)).count, group.reduce(0) { $0 + $1.inliers }, mean.description, usable.count - group.count,
                             rejected.count, rejected.map(\.inliers).max() ?? 0))
            } else {
                let best = links.max { $0.inliers < $1.inliers }!
                print(String(format: "%@ → %@: not linked (%d view links, the best %d matches)", a, b, links.count, best.inliers))
            }
        }
    }
    // Triangles: A→C directly against A→B then B→C, at A's evidence of the A→C link.
    print("triangles:")
    var any = false
    for (i, a) in names.enumerated() {
        for (j, b) in names.enumerated() where j > i {
            for c in names[(j + 1)...] {
                guard let ab = linked["\(a)→\(b)"], let bc = linked["\(b)→\(c)"], let ac = linked["\(a)→\(c)"] else { continue }
                any = true
                var worst: Float = 0
                for l in ac.group {
                    let p = l.centre
                    guard let pb = SessionLink.carry(p, by: ab.group), let pc = SessionLink.carry(pb, by: bc.group), let direct = SessionLink.carry(p, by: ac.group) else { continue }
                    worst = max(worst, simd_distance(pc, direct))
                }
                print(String(format: "  %@→%@→%@ against %@→%@: up to %.1f cm apart", a, b, c, a, c, worst * 100))
            }
        }
    }
    if !any { print("  (no three sessions linked to each other)") }
}

// pipeval livelink <memory/frames folder> <stored piece> <live piece>
//   The live piece's snapshots, in the order they were taken, play the live views (as SpaceLinker
//   gets them, every 1.5 s): after how many the stored session is linked, and what the links say.
func liveLink(_ args: [String]) {
    guard args.count >= 4 else { fail("pipeval livelink <memory/frames> <stored piece> <live piece>") }
    let dir = URL(fileURLWithPath: args[1])
    let views = loadViews(dir, pieces: [args[2], args[3]])
    let stored = views.filter { pieceName($0).hasPrefix(args[2]) }
    let live = views.filter { pieceName($0).hasPrefix(args[3]) }.sorted { $0.frame.time < $1.frame.time }
    let settings = SessionLink.Settings()
    var found: [ViewLink] = []
    var linkedAt: Int?
    for (n, v) in live.enumerated() {
        for (i, s) in stored.enumerated() {
            if let l = SessionLink.link(s.points, v.points, from: i, to: n, settings: settings) { found.append(l) }
        }
        if linkedAt == nil, let core = SessionLink.consensus(found, settings: settings) {
            linkedAt = n
            let usable = SessionLink.usable(found, core: core, settings: settings)
            print(String(format: "linked at live view %d of %d (%.0f s into the session): %d views agree, %d matches; %d usable, %d rejected",
                         n + 1, live.count, v.frame.time - live[0].frame.time, Set(core.map(\.to)).count, core.reduce(0) { $0 + $1.inliers },
                         usable.count, found.count - usable.count))
        }
    }
    if linkedAt == nil { print("not linked after \(live.count) live views (\(found.count) view links)") }
    print("view links per live view: " + live.indices.map { n in String(found.filter { $0.to == n }.count) }.joined(separator: " "))
}
