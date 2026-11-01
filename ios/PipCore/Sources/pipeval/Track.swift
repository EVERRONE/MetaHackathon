import CoreGraphics
import Foundation
import ImageIO
import PipCore
import UniformTypeIdentifiers
import simd

// pipeval track <clip folder> <phrase> [x y] [--every N] [--out dir]
//
// Replays a test clip from the app (video.mov, frames.jsonl, depth-*.f16) through PlanarTracker:
// SAM finds `phrase` on the first frame (at x, y in its upright pixels, or the middle), the
// tracker follows it through every frame, and every N frames SAM finds it again on that frame,
// independently: how far the tracked outline is from SAM's (centre, in pixels and millimetres at
// the object's depth, and the overlap). Frames with the tracked outline drawn go to the out folder.

struct ClipFrame: Decodable {
    var i: Int
    var t: Double
    var intrinsics: [Float]
    var w: Double
    var h: Double
    var depth: String
}

func trackClip(_ args: [String]) async {
    let env = ProcessInfo.processInfo.environment
    guard args.count >= 3 else { fail("pipeval track <clip folder> <phrase> [x y] [--every N] [--out dir]") }
    let clip = URL(fileURLWithPath: args[1])
    let phrase = args[2]
    let point: CGPoint? = args.count >= 5 ? Double(args[3]).flatMap { x in Double(args[4]).map { CGPoint(x: x, y: $0) } } : nil
    let every = args.firstIndex(of: "--every").flatMap { Int(args[$0 + 1]) } ?? 10
    let out = URL(fileURLWithPath: args.firstIndex(of: "--out").map { args[$0 + 1] } ?? clip.appendingPathComponent("replay").path)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let client = PipClient(baseURL: URL(string: env["PIP_URL"] ?? "https://pip.unveil.be")!, token: env["PIP_APP_TOKEN"] ?? "")

    // Frames, upright, as the app's snapshots are: grey at the tracking size, colour for SAM.
    let frames = clip.appendingPathComponent("frames")
    if !FileManager.default.fileExists(atPath: frames.appendingPathComponent("g0001.pgm").path) {
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        func ffmpeg(_ a: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            p.arguments = ["-loglevel", "error", "-i", clip.appendingPathComponent("video.mov").path] + a
            try? p.run()
            p.waitUntilExit()
        }
        ffmpeg(["-vf", "transpose=1,scale=720:960,format=gray", frames.appendingPathComponent("g%04d.pgm").path])
        ffmpeg(["-vf", "transpose=1", "-q:v", "2", frames.appendingPathComponent("c%04d.jpg").path])
    }
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: frames.path)) ?? []).filter { $0.hasPrefix("g") }.sorted()
    guard !names.isEmpty else { fail("no frames in \(frames.path)") }
    let meta: [ClipFrame] = ((try? String(contentsOf: clip.appendingPathComponent("frames.jsonl"), encoding: .utf8)) ?? "")
        .split(separator: "\n").compactMap { try? JSONDecoder().decode(ClipFrame.self, from: Data($0.utf8)) }

    func grey(_ n: Int) -> GrayImage? { readPGM(frames.appendingPathComponent(String(format: "g%04d.pgm", n + 1))) }
    func colour(_ n: Int) -> CGImage? {
        FileManager.default.contents(atPath: frames.appendingPathComponent(String(format: "c%04d.jpg", n + 1)).path).flatMap { SetOfMarks.load($0, maxSide: 4096) }
    }
    guard let g0 = grey(0), let c0 = colour(0) else { fail("cannot read the first frame") }
    // Colour frames are full size; the tracker works at 720×960.
    let scale = CGFloat(g0.width) / CGFloat(c0.width)
    let grounder = Grounder(client: client, frameJPEG: Data())
    let seedPoint = point ?? CGPoint(x: CGFloat(c0.width) / 2, y: CGFloat(c0.height) / 2)
    guard let seed = await grounder.object(named: phrase, at: seedPoint, in: c0, id: 1), let ring = seed.outlinePoints.first else { fail("SAM finds no \(phrase) on the first frame") }
    let outline = ring.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
    let centre0 = CGPoint(x: seed.centre.x * scale, y: seed.centre.y * scale)

    // The object's distance, for millimetres: depth at its centre on the first frame (the depth map is
    // in sensor orientation: upright (u, v) is sensor (v, 1 − u)).
    var distance: Float = 0.4
    if let m = meta.first, !m.depth.isEmpty, let d = readDepth(clip.appendingPathComponent(m.depth)) {
        let u = Float(seed.centre.x) / Float(c0.width), v = Float(seed.centre.y) / Float(c0.height)
        let sx = Int(v * Float(d.w - 1)), sy = Int((1 - u) * Float(d.h - 1))
        let value = d.values[sy * d.w + sx]
        if value.isFinite, value > 0.05 { distance = value }
    }
    // Focal length in tracking pixels (intrinsics are of the sensor image).
    let fx = meta.first.map { $0.intrinsics[0] * Float(g0.height) / Float($0.w) } ?? 700
    func mm(_ px: Double) -> Double { px / Double(fx) * Double(distance) * 1000 }

    var tracker = PlanarTracker()
    guard tracker.start(image: g0, outline: outline) else { fail("too few corners on the \(phrase)") }
    print(String(format: "seed: %@ at %.0f,%.0f, %d points, %.2f m away, %d frames", phrase, centre0.x, centre0.y, tracker.inliers, distance, names.count))
    var checks: [(frame: Int, px: Double, iou: Double)] = []
    var lostAt: [Int] = []
    var times: [Double] = []
    for n in 1..<names.count {
        guard let g = grey(n) else { continue }
        let t0 = Date()
        let state = tracker.track(g)
        times.append(Date().timeIntervalSince(t0) * 1000)
        if state == .lost {
            lostAt.append(n)
            print("frame \(n): lost")
            // Started again from SAM, as the app would.
            if let c = colour(n), let inst = await grounder.object(named: phrase, at: CGPoint(x: seed.centre.x, y: seed.centre.y), in: c, id: 1), let r = inst.outlinePoints.first {
                tracker.start(image: g, outline: r.map { CGPoint(x: $0.x * scale, y: $0.y * scale) })
            } else { break }
            continue
        }
        let shown = outline.map { tracker.map($0) }
        if n % every == 0 || n == names.count - 1, let c = colour(n) {
            let centre = tracker.map(centre0)
            let at = CGPoint(x: centre.x / scale, y: centre.y / scale)
            if let truth = await grounder.object(named: phrase, at: at, in: c, id: 1), let tr = truth.outlinePoints.first {
                let truthRing = tr.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
                let px = hypot(Double(centroid(shown).x - centroid(truthRing).x), Double(centroid(shown).y - centroid(truthRing).y))
                let iou = overlap(shown, truthRing, width: g.width, height: g.height)
                checks.append((n, px, iou))
                print(String(format: "frame %3d  %3d points, residual %.2f px  |  vs SAM: centre %.1f px (%.1f mm), overlap %.2f", n, tracker.inliers, tracker.residual, px, mm(px), iou))
            }
            draw(c, outline: shown.map { CGPoint(x: $0.x / scale, y: $0.y / scale) }, to: out.appendingPathComponent(String(format: "f%04d.jpg", n)))
        }
    }
    let pxs = checks.map(\.px).sorted(), ious = checks.map(\.iou).sorted()
    let median = { (xs: [Double]) in xs.isEmpty ? 0 : xs[xs.count / 2] }
    print(String(format: "summary: %d checks, centre median %.1f px (%.1f mm), max %.1f px (%.1f mm); overlap median %.2f, min %.2f; lost %d times; %.1f ms a frame",
                 checks.count, median(pxs), mm(median(pxs)), pxs.last ?? 0, mm(pxs.last ?? 0), median(ious), ious.first ?? 0, lostAt.count,
                 times.reduce(0, +) / Double(max(times.count, 1))))
}

func centroid(_ ring: [CGPoint]) -> CGPoint {
    guard !ring.isEmpty else { return .zero }
    return CGPoint(x: ring.map(\.x).reduce(0, +) / CGFloat(ring.count), y: ring.map(\.y).reduce(0, +) / CGFloat(ring.count))
}

/// Intersection over union of two polygons, on a 2-pixel grid.
func overlap(_ a: [CGPoint], _ b: [CGPoint], width: Int, height: Int) -> Double {
    func inside(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        var c = false
        var j = poly.count - 1
        for i in poly.indices {
            if (poly[i].y > p.y) != (poly[j].y > p.y), p.x < (poly[j].x - poly[i].x) * (p.y - poly[i].y) / (poly[j].y - poly[i].y) + poly[i].x { c.toggle() }
            j = i
        }
        return c
    }
    let box = (a + b).reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    guard !box.isNull else { return 0 }
    var both = 0, either = 0
    for y in stride(from: box.minY, to: box.maxY, by: 2) {
        for x in stride(from: box.minX, to: box.maxX, by: 2) {
            let p = CGPoint(x: x, y: y), ia = inside(p, a), ib = inside(p, b)
            if ia || ib { either += 1 }
            if ia && ib { both += 1 }
        }
    }
    return either == 0 ? 0 : Double(both) / Double(either)
}

func readPGM(_ url: URL) -> GrayImage? {
    guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
    // "P5\n<w> <h>\n255\n" then the bytes.
    var fields: [String] = []
    var i = 0
    var current = ""
    while fields.count < 4, i < data.count {
        let c = Character(UnicodeScalar(data[i]))
        if c.isWhitespace { if !current.isEmpty { fields.append(current); current = "" } } else { current.append(c) }
        i += 1
    }
    guard fields.count == 4, fields[0] == "P5", let w = Int(fields[1]), let h = Int(fields[2]), data.count - i >= w * h else { return nil }
    return GrayImage(width: w, height: h, pixels: data[i..<(i + w * h)].map { Float($0) })
}

func readDepth(_ url: URL) -> (w: Int, h: Int, values: [Float])? {
    guard let data = FileManager.default.contents(atPath: url.path), data.count == 256 * 192 * 2 else { return nil }
    let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }.map { Float($0) }
    return (256, 192, values)
}

func draw(_ image: CGImage, outline: [CGPoint], to url: URL) {
    let w = image.width, h = image.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setStrokeColor(CGColor(red: 0.2, green: 1, blue: 0.9, alpha: 1))
    ctx.setLineWidth(4)
    ctx.addLines(between: outline)
    ctx.closePath()
    ctx.strokePath()
    guard let img = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
    CGImageDestinationFinalize(dest)
}
