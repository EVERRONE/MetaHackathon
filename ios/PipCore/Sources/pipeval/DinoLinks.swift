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
    let views = loadDinoViews(dir, pieces: pieces, features: features, minDepth: linkSettings.minDepth)
    print(String(format: "%d snapshots described in %.1f s", views.count, Date().timeIntervalSince(t0)))
    let byPiece = Dictionary(grouping: views) { String(($0.frame.piece ?? "????").prefix(4)) }
    for (i, p) in pieces.enumerated() {
        for q in pieces[(i + 1)...] {
            guard let a = byPiece[p], let b = byPiece[q] else { continue }
            let t1 = Date()
            var links: [ViewLink] = []
            var outcomes: [String: Int] = [:]
            var bestTry: (matches: Int, ransac: Int, overlap: Float, rms: Float, turn: Float) = (0, 0, 0, 0, 0)
            for (ib, vb) in b.enumerated() {
                let ranked = a.indices.sorted { a[$0].view.features.similarity(to: vb.view.features) > a[$1].view.features.similarity(to: vb.view.features) }
                for ia in ranked.prefix(top) {
                    var trace = DinoLink.Trace()
                    if let l = DinoLink.link(a[ia].view, vb.view, from: ia, to: ib, settings: linkSettings, trace: &trace) { links.append(l) }
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
            }
            for l in links.sorted(by: { $0.inliers > $1.inliers }).prefix(12) {
                print(String(format: "  A%03d → B%03d: %2d agree, laid to %.1f cm, at (%.2f, %.2f, %.2f) reach %.2f m: %@", l.from, l.to, l.inliers, l.residual * 100,
                             l.centre.x, l.centre.y, l.centre.z, l.reach, l.transform.description))
            }
            if let group = SessionLink.consensus(links, settings: consensusSettings) {
                let core = group.max { $0.inliers < $1.inliers }!
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
