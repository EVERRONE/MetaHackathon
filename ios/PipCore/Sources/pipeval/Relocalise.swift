import CoreGraphics
import Foundation
import ImageIO
import PipCore
import simd
import Vision

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
            var samples: [Float] = []
            for y in max(0, dy - 1)...min(f.depthH - 1, dy + 1) {
                for x in max(0, dx - 1)...min(f.depthW - 1, dx + 1) { samples.append(depth[y * f.depthW + x]) }
            }
            // The app's rule (TrustedDepth), as Keyframes.storedPoint uses it.
            guard let d = TrustedDepth.of(samples) else { return nil }
            return f.world(p, depth: d)
        }
        let camera = SIMD3(f.transform.columns.3.x, f.transform.columns.3.y, f.transform.columns.3.z)
        return StoredView(frame: f, points: ViewPoints(image: grey, camera: camera, lift: lift))
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
        print(String(format: "A%03d ↔ B%03d: %3d agree (median %.1f cm, spread %.0f cm, reach %.0f cm): %@", l.from, l.to, l.inliers, l.residual * 100, l.spread * 100, l.reach * 100, l.transform.description))
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

// pipeval livelink <memory/frames folder> <stored pieces, comma-separated> <live piece>
//   The live piece's snapshots, in the order they were taken, play the live views, through the very
//   code the app runs (LinkBook, LinkSchedule, the same batch sizes and neighbours): after how many
//   live views each stored session is linked, and how.
func liveLink(_ args: [String]) {
    guard args.count >= 4 else { fail("pipeval livelink <memory/frames> <stored pieces A,B,…> <live piece>") }
    let dir = URL(fileURLWithPath: args[1])
    let storedPieces = args[2].split(separator: ",").map(String.init)
    let views = loadViews(dir, pieces: Set(storedPieces + [args[3]]))
    // As SpaceLinker: by session, then in the order taken.
    let stored = views.filter { v in storedPieces.contains { pieceName(v).hasPrefix($0) } }
        .sorted { (pieceName($0), $0.frame.time) < (pieceName($1), $1.frame.time) }
    let live = views.filter { pieceName($0).hasPrefix(args[3]) }.sorted { $0.frame.time < $1.frame.time }
    var book = LinkBook()
    var schedule = LinkSchedule()
    let ready = Array(stored.indices)
    func viewPrint(_ v: StoredView) -> ViewPrint? {
        FileManager.default.contents(atPath: dir.appendingPathComponent("\(v.frame.id).jpg").path).flatMap { SetOfMarks.load($0, maxSide: 4096) }.flatMap(ViewPrint.init)
    }
    var prints: [Int: ViewPrint] = [:]
    for i in stored.indices { prints[i] = viewPrint(stored[i]) }
    func neighbours(_ v: Int) -> [Int] { [v - 1, v + 1, v - 2, v + 2].filter { stored.indices.contains($0) && pieceName(stored[$0]) == pieceName(stored[v]) } }
    var perView: [Int] = []
    for (n, v) in live.enumerated() {
        let hot = book.hot(limit: 24, neighbours: neighbours)
        let lookAlike = viewPrint(v)?.nearest(20, among: prints) ?? []
        let batch = schedule.next(ready: ready, lookAlike: lookAlike, hot: hot, count: 60)
        var found: [(session: UUID, link: ViewLink)] = []
        for i in batch {
            if let l = SessionLink.link(stored[i].points, v.points, from: i, to: n, settings: book.settings), let s = stored[i].frame.piece.flatMap(UUID.init) {
                found.append((s, l))
            }
        }
        perView.append(found.count)
        for (session, change) in book.add(found) where change != .strengthened {
            let l = book.linked[session]!
            print(String(format: "%@ %@ at live view %d of %d (%.0f s in): %d views agree, %d matches over %.1f m; %d usable",
                         change == .linked ? "linked" : "relinked", String(session.uuidString.prefix(4)), n + 1, live.count,
                         v.frame.time - live[0].frame.time, l.views, l.matches, l.extent, l.usable.count))
        }
    }
    if book.linked.isEmpty { print("not linked after \(live.count) live views") }
    print("view links per live view: " + perView.map(String.init).joined(separator: " "))
}

// pipeval retrieval <memory/frames folder> <stored pieces, comma-separated> <live piece>
//   Does looking up stored views by image fingerprint (Apple Vision's feature print) find the ones a
//   live view really links to? For every live view with a view link (all stored views tried), the
//   rank of its linked stored views among all, by fingerprint distance: recall at 5, 10, 20, 40.
func retrieval(_ args: [String]) {
    guard args.count >= 4 else { fail("pipeval retrieval <memory/frames> <stored pieces A,B,…> <live piece>") }
    let dir = URL(fileURLWithPath: args[1])
    let storedPieces = args[2].split(separator: ",").map(String.init)
    let views = loadViews(dir, pieces: Set(storedPieces + [args[3]]))
    let stored = views.filter { v in storedPieces.contains { pieceName(v).hasPrefix($0) } }
    let live = views.filter { pieceName($0).hasPrefix(args[3]) }.sorted { $0.frame.time < $1.frame.time }
    func print_(_ v: StoredView) -> VNFeaturePrintObservation? {
        guard let jpeg = FileManager.default.contents(atPath: dir.appendingPathComponent("\(v.frame.id).jpg").path),
              let image = SetOfMarks.load(jpeg, maxSide: 4096) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }
    let t0 = Date()
    let storedPrints = stored.map(print_), livePrints = live.map(print_)
    print(String(format: "%d fingerprints in %.1f s", stored.count + live.count, Date().timeIntervalSince(t0)))
    var ranks: [Int] = []
    var liveWithLinks = 0
    for (n, v) in live.enumerated() {
        guard let lp = livePrints[n] else { continue }
        let linkedTo = stored.indices.filter { SessionLink.link(stored[$0].points, v.points, from: $0, to: n) != nil }
        guard !linkedTo.isEmpty else { continue }
        liveWithLinks += 1
        var d = [Float](repeating: .infinity, count: stored.count)
        for (i, sp) in storedPrints.enumerated() {
            guard let sp else { continue }
            var x: Float = 0
            try? lp.computeDistance(&x, to: sp)
            d[i] = x
        }
        let order = stored.indices.sorted { d[$0] < d[$1] }
        // The best-ranked of the stored views it links to: the first one retrieval would hand over.
        let best = linkedTo.map { i in order.firstIndex(of: i)! }.min()!
        ranks.append(best)
    }
    print("live views with a view link: \(liveWithLinks) of \(live.count)")
    for k in [5, 10, 20, 40] {
        print(String(format: "  a linked stored view among the first %2d by fingerprint: %d of %d", k, ranks.filter { $0 < k }.count, ranks.count))
    }
    print("  ranks: " + ranks.map(String.init).joined(separator: " "))
}
