import CoreGraphics
import Foundation
import PipCore
import simd

// pipeval dinolinks <memory/frames> <A,B,…> [--model DINOv2Small.mlpackage] [--top K]
//   Every pair of sessions linked across light (DinoLink: DINOv2 patches, then the depth): each of
//   the later session's snapshots against the earlier one's K most alike (DINOv2 class token), the
//   view links, and whether they make a session link (SessionLink.consensus).

struct DinoStored {
    var frame: StoredFrame
    var view: DinoLink.View
}

func loadDinoViews(_ dir: URL, pieces: [String], features: ViewFeatures, minDepth: Float = DinoLink.Settings().minDepth) -> [DinoStored] {
    guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent("index.json").path),
          let all = try? JSONDecoder().decode([StoredFrame].self, from: data) else { fail("cannot read index.json") }
    let wanted = all.filter { f in pieces.contains { f.piece?.hasPrefix($0) == true } }.sorted { $0.time < $1.time }
    return wanted.compactMap { f -> DinoStored? in
        guard let jpeg = FileManager.default.contents(atPath: dir.appendingPathComponent("\(f.id).jpg").path),
              let image = SetOfMarks.load(jpeg, maxSide: 4096),
              let raw = FileManager.default.contents(atPath: dir.appendingPathComponent("\(f.id).depth").path),
              raw.count == f.depthW * f.depthH * 2, f.intrinsics.count == 9,
              let described = try? features.describe(image) else { return nil }
        let depth = raw.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }.map { Float($0) }
        let k = f.intrinsics
        let intrinsics = simd_float3x3(columns: (SIMD3(k[0], k[1], k[2]), SIMD3(k[3], k[4], k[5]), SIMD3(k[6], k[7], k[8])))
        let view = DepthView(width: f.width, height: f.height, sensorWidth: Float(f.sensorWidth), sensorHeight: Float(f.sensorHeight),
                             intrinsics: intrinsics, pose: f.transform, depthW: f.depthW, depthH: f.depthH, depth: depth)
        return DinoStored(frame: f, view: DinoLink.View(features: described, depth: view, minDepth: minDepth))
    }
}

func dinoLinks(_ args: [String]) {
    guard args.count >= 3 else { fail("pipeval dinolinks <memory/frames> <A,B,…> [--model DINOv2Small.mlpackage] [--top K]") }
    let dir = URL(fileURLWithPath: args[1])
    let pieces = args[2].split(separator: ",").map(String.init)
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let modelPath = args.firstIndex(of: "--model").map { args[$0 + 1] }
        ?? here.appendingPathComponent("../../../Models/DINOv2/DINOv2Small.mlpackage").standardized.path
    let top = args.firstIndex(of: "--top").map { Int(args[$0 + 1]) ?? 4 } ?? 4
    let t0 = Date()
    let features: ViewFeatures
    do { features = try ViewFeatures.load(from: URL(fileURLWithPath: modelPath)) } catch { fail("cannot load \(modelPath): \(error)") }
    var consensusSettings = SessionLink.Settings()
    if let i = args.firstIndex(of: "--min-total") { consensusSettings.minTotalInliers = Int(args[i + 1]) ?? consensusSettings.minTotalInliers }
    var linkSettings = DinoLink.Settings()
    if let i = args.firstIndex(of: "--min-depth"), let v = Float(args[i + 1]) { linkSettings.minDepth = v }
    if let i = args.firstIndex(of: "--min-inliers"), let v = Int(args[i + 1]) { linkSettings.minInliers = v }
    if let i = args.firstIndex(of: "--inlier-distance"), let v = Float(args[i + 1]) { linkSettings.inlierDistance = v }
    let views = loadDinoViews(dir, pieces: pieces, features: features, minDepth: linkSettings.minDepth)
    print(String(format: "%d snapshots described in %.1f s", views.count, Date().timeIntervalSince(t0)))
    let byPiece = Dictionary(grouping: views) { String(($0.frame.piece ?? "????").prefix(4)) }
    for (i, p) in pieces.enumerated() {
        for q in pieces[(i + 1)...] {
            guard let a = byPiece[p], let b = byPiece[q] else { continue }
            let t1 = Date()
            var links: [ViewLink] = []
            var outcomes: [String: Int] = [:]
            var uncertainties: [Float] = []
            var bestTry: (matches: Int, ransac: Int, overlap: Float, rms: Float, turn: Float) = (0, 0, 0, 0, 0)
            var keptOf: [String: (close: Int, kept: Int, corrected: Float)] = [:]
            func pairKey(_ l: ViewLink) -> String { "\(l.from)-\(l.to)" }
            for (ib, vb) in b.enumerated() {
                let ranked = a.indices.sorted { a[$0].view.features.similarity(to: vb.view.features) > a[$1].view.features.similarity(to: vb.view.features) }
                for ia in ranked.prefix(top) {
                    var trace = DinoLink.Trace()
                    defer {
                        if args.contains("--trace-pairs") {
                            print(String(format: "    pair A%03d B%03d sim %.2f: %@; points %d/%d, matches %d, ransac %d, overlap %.0f%%, rms %.1f cm, shift sd %.1f mm, kept %d of %d%@",
                                         ia, ib, a[ia].view.features.similarity(to: vb.view.features), trace.outcome, trace.pointsA, trace.pointsB, trace.matches,
                                         trace.ransac, trace.overlap * 100, trace.rms * 100, trace.shiftUncertainty * 1000, trace.kept, trace.close,
                                         trace.laid.map { "; laid: " + $0.description } ?? ""))
                        }
                    }
                    if let l = DinoLink.link(a[ia].view, vb.view, from: ia, to: ib, settings: linkSettings, trace: &trace) {
                        links.append(l)
                        uncertainties.append(trace.shiftUncertainty)
                        keptOf[pairKey(l)] = (trace.close, trace.kept, trace.correctionTurn * 180 / .pi)
                    }
                    outcomes[trace.outcome, default: 0] += 1
                    if trace.ransac > bestTry.ransac || (trace.ransac == bestTry.ransac && trace.matches > bestTry.matches) {
                        bestTry = (trace.matches, trace.ransac, trace.overlap, trace.rms, trace.correctionTurn * 180 / .pi)
                    }
                }
            }
            let ms = Date().timeIntervalSince(t1) * 1000 / Double(max(1, b.count))
            print(String(format: "%@ → %@: %d view links from %d views (%.0f ms per view)", p, q, links.count, b.count, ms))
            if args.contains("--trace") {
                print("  outcomes:", outcomes.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                print(String(format: "  furthest: %d matches, %d agree, depth overlap %.0f%%, rms %.1f cm, corrected %.1f°", bestTry.matches, bestTry.ransac,
                             bestTry.overlap * 100, bestTry.rms * 100, bestTry.turn))
                print(String(format: "  surfaces' shift uncertainty of the links: %@", uncertainties.sorted().map { String(format: "%.1f", $0 * 1000) }.joined(separator: " ") + " mm"))
            }
            for l in links.sorted(by: { $0.inliers > $1.inliers }).prefix(args.contains("--all-links") ? 1000 : 12) {
                print(String(format: "  A%03d → B%03d: %2d agree, laid to %.1f cm, at (%.2f, %.2f, %.2f) reach %.2f m: %@", l.from, l.to, l.inliers, l.residual * 100,
                             l.centre.x, l.centre.y, l.centre.z, l.reach, l.transform.description))
            }
            if let group = SessionLink.consensus(links, settings: consensusSettings) {
                let core = group.max { $0.inliers < $1.inliers }!
                // Each view link against the consensus, at its own evidence: right (within 3° and 15 cm)
                // or wrong, with the appearance's matches its fit kept and the depth's fit kept.
                if args.contains("--verdicts") {
                    let usableNow = SessionLink.usable(links, core: group, settings: consensusSettings)
                    for l in links.sorted(by: { ($0.to, $0.from) < ($1.to, $1.from) }) {
                        let k = keptOf[pairKey(l)] ?? (0, 0, 0)
                        let off = simd_distance(l.transform.apply(l.centre), core.transform.apply(l.centre))
                        let turn = abs(l.transform.turn(to: core.transform)) * 180 / .pi
                        print(String(format: "    VERDICT %@ A%03d→B%03d close %d kept %d corrected %.1f°: off %.0f cm %.1f°", usableNow.contains(l) ? "right" : "WRONG",
                                     l.from, l.to, k.close, k.kept, k.corrected, off * 100, turn))
                    }
                }
                let usable = SessionLink.usable(links, core: group, settings: consensusSettings)
                print(String(format: "  LINKED: %d views agree, %d matches, over %.1f m; %d more within drift, %d not used; %@", Set(group.map(\.to)).count,
                             group.reduce(0) { $0 + $1.inliers }, SessionLink.extent(group), usable.count - group.count, links.count - usable.count,
                             core.transform.description))
                // Where a point is carried, by the evidence nearest it, against the core alone: at each
                // view link's evidence (the session's drift between its parts).
                for l in usable.sorted(by: { $0.inliers > $1.inliers }).prefix(6) {
                    guard let near = SessionLink.carry(l.centre, by: usable) else { continue }
                    print(String(format: "    at (%.1f, %.1f, %.1f): by the nearest evidence %.1f cm from the core's carry", l.centre.x, l.centre.y, l.centre.z,
                                 simd_distance(near, core.transform.apply(l.centre)) * 100))
                }
            } else {
                print("  not linked")
            }
        }
    }
}

// pipeval dinolive <memory/frames> <stored pieces A,B,…> <live piece> [--as-built] [--delay s] [--interval s]
//   [--per-view n] [--new-per-view n] [--trace]
//   The live session's snapshots as its live views, in the order taken, laid across light against the
//   stored views as SpaceLinker does (the most alike by DINOv2's whole-view token, DinoLink, the
//   LinkBook): when each earlier session would be linked, in seconds after the session began (3 s
//   before its first snapshot). The stored views' whole-view tokens are there from `delay` on (kept
//   beside the snapshots); with --as-built they come as the build of 2 Nov 18:26 made them at each
//   start: from `delay` on, one per 0.25 s, the newest snapshots first.
func dinoLive(_ args: [String]) {
    guard args.count >= 4 else { fail("pipeval dinolive <memory/frames> <stored pieces A,B,…> <live piece> [--as-built] [--delay s] [--trace]") }
    let dir = URL(fileURLWithPath: args[1])
    let storedPieces = args[2].split(separator: ",").map(String.init)
    let livePiece = args[3]
    func value(_ name: String, _ fallback: Double) -> Double { args.firstIndex(of: name).flatMap { Double(args[$0 + 1]) } ?? fallback }
    let delay = value("--delay", 8), interval = value("--interval", 3), searchingInterval = value("--searching-interval", 3)
    let perView = Int(value("--per-view", 3)), perViewSearching = Int(value("--per-view-searching", 4)), newPerView = Int(value("--new-per-view", 2))
    let asBuilt = args.contains("--as-built"), trace = args.contains("--trace")
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let modelPath = here.appendingPathComponent("../../../Models/DINOv2/DINOv2Small.mlpackage").standardized.path
    let features: ViewFeatures
    do { features = try ViewFeatures.load(from: URL(fileURLWithPath: modelPath)) } catch { fail("cannot load \(modelPath): \(error)") }
    let all = loadDinoViews(dir, pieces: storedPieces + [livePiece], features: features)
    func piece(_ v: DinoStored) -> String { v.frame.piece ?? "" }
    // As SpaceLinker: by session, then in the order taken.
    let stored = all.filter { v in storedPieces.contains { piece(v).hasPrefix($0) } }.sorted { (piece($0), $0.frame.time) < (piece($1), $1.frame.time) }
    let live = all.filter { piece($0).hasPrefix(livePiece) }.sorted { $0.frame.time < $1.frame.time }
    guard let first = live.first else { fail("no snapshots of \(livePiece)") }
    let begin = first.frame.time - 3
    // When each stored view's whole-view token is there (seconds after the session began).
    var available = [Double](repeating: delay, count: stored.count)
    if asBuilt {
        // Their corners are described four per half second, in order; from `delay` on, one whole-view
        // token per 0.25 s, the newest described snapshot first.
        let described = stored.indices.map { 0.5 * Double($0 / 4 + 1) }
        var done = Set<Int>(), t = delay
        while done.count < stored.count {
            let pending = stored.indices.filter { described[$0] <= t && !done.contains($0) }
            if let i = pending.max(by: { stored[$0].frame.time < stored[$1].frame.time }) {
                available[i] = t + 0.1
                done.insert(i)
            }
            t += 0.25
        }
    }
    // A stored view by its session and its number in it, as `dinolinks` numbers them.
    let firstOf = Dictionary(stored.indices.reversed().map { (piece(stored[$0]), $0) }, uniquingKeysWith: { _, first in first })
    let name = { (i: Int) -> String in String(piece(stored[i]).prefix(4)) + String(format: ":%03d", i - (firstOf[piece(stored[i])] ?? 0)) }
    var book = LinkBook()
    var prepared: [Int] = []
    var lastDino = -Double.infinity
    print(String(format: "%d stored views, %d live views; whole-view tokens %@", stored.count, live.count,
                 asBuilt ? "as built on 2 Nov 18:26 (all there \(String(format: "%.0f", available.max() ?? 0)) s in)" : "there from \(String(format: "%.0f", delay)) s on"))
    for (n, v) in live.enumerated() {
        let t = v.frame.time - begin
        let searching = book.linked.isEmpty
        guard t >= delay, t - lastDino >= (searching ? searchingInterval : interval) else { continue }
        lastDino = t
        let candidates = stored.indices.filter { available[$0] <= t }
        let ranked = candidates.map { ($0, stored[$0].view.features.similarity(to: v.view.features)) }.sorted { $0.1 > $1.1 }
            .prefix(searching ? perViewSearching : perView)
        var newLeft = newPerView
        var found: [(session: UUID, link: ViewLink)] = []
        var tried: [String] = []
        for (i, sim) in ranked {
            if let k = prepared.firstIndex(of: i) {
                prepared.remove(at: k)
            } else {
                guard newLeft > 0 else { tried.append(name(i) + " (waits)"); continue }
                newLeft -= 1
            }
            prepared.append(i)
            if prepared.count > 16 { prepared.removeFirst() }
            if let l = DinoLink.link(stored[i].view, v.view, from: i, to: n), let s = UUID(uuidString: piece(stored[i])) {
                found.append((s, l))
                tried.append(String(format: "%@ %.2f LINK %d agree %@", name(i), sim, l.inliers, l.transform.description))
            } else {
                tried.append(String(format: "%@ %.2f", name(i), sim))
            }
        }
        if trace {
            print(String(format: "  %5.1f s  live %@%03d (%d of %d wholes): %@", t, String(livePiece.prefix(1)), n, candidates.count, stored.count,
                         tried.joined(separator: " | ")))
        }
        for (session, change) in book.add(found) where change != .strengthened {
            let l = book.linked[session]!
            let core = l.core.max { $0.inliers < $1.inliers }!
            print(String(format: "%@ %@ at %.1f s (live view %d): %d views agree, %d matches over %.1f m; %@", change == .linked ? "LINKED" : "relinked",
                         String(session.uuidString.prefix(4)), t, n, l.views, l.matches, l.extent, core.transform.description))
        }
    }
    if book.linked.isEmpty { print("not linked") }
}
