import CoreGraphics
import Foundation
import ImageIO
import PipCore
import UniformTypeIdentifiers
import simd

// pipeval alias <clip folder> <x> <y> [text]
//
// Taking an object up again on a real clip, against look-alikes. The key at x, y (upright pixels
// of the clip's first frame; `text` what is printed on it, e.g. ⏻) is grounded as the app does, and
// the keyboard round it is the followed region (clipped to six key sizes round it, as the app does).
// The key is followed through the clip frame by frame: the truth. Then on every 30th frame it is
// taken up again from the first frame with a prediction shifted by −2 … +2 key widths along the
// row: by alignment alone (`relocate`, before 1 Nov evening) and checked by the described corners
// (`reacquire`). Prints how often each lands on the right key, on a look-alike, or nowhere, and how
// often the watch (`confirmed`) disagrees with the true track. The true track is drawn every 60
// frames to <clip>/alias, to check it by eye.

func aliasClip(_ args: [String]) async {
    let env = ProcessInfo.processInfo.environment
    guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else { fail("pipeval alias <clip folder> <x> <y> [text]") }
    let clip = URL(fileURLWithPath: args[1])
    let text = args.count > 4 ? CueTag.alternatives(args[4]) : []
    let client = PipClient(baseURL: URL(string: env["PIP_URL"] ?? "https://pip.unveil.be")!, token: env["PIP_APP_TOKEN"] ?? "")

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
    let count = ((try? FileManager.default.contentsOfDirectory(atPath: frames.path)) ?? []).filter { $0.hasPrefix("g") }.count
    func grey(_ n: Int) -> GrayImage? { readPGM(frames.appendingPathComponent(String(format: "g%04d.pgm", n + 1))) }
    func colour(_ n: Int) -> CGImage? {
        FileManager.default.contents(atPath: frames.appendingPathComponent(String(format: "c%04d.jpg", n + 1)).path).flatMap { SetOfMarks.load($0, maxSide: 4096) }
    }
    guard count > 30, let g0 = grey(0), let c0 = colour(0) else { fail("cannot read the clip's frames") }
    let s = CGFloat(g0.width) / CGFloat(c0.width)

    // The key, as the app grounds it, and the keyboard round it.
    let spec = TargetSpec(x: x / Double(c0.width) * 1000, y: y / Double(c0.height) * 1000, phrase: "key", text: text, on: "keyboard", small: true)
    let grounder = Grounder(client: client, frameJPEG: SetOfMarks.jpeg(c0) ?? Data())
    let grounded = await grounder.ground(spec, id: 1, frame: c0)
    guard let key = grounded.instance else { fail("the key is not found on the first frame (\(grounded.method))") }
    let keyBox = key.boxRect
    let side = max(max(keyBox.width, keyBox.height), 0.05 * CGFloat(c0.width))
    let bounds = CGRect(x: 0, y: 0, width: c0.width, height: c0.height)
    var region: [CGPoint]
    if let board = await grounder.object(named: "keyboard", at: CGPoint(x: keyBox.midX, y: keyBox.midY), in: c0, id: 0),
       let ring = board.outlinePoints.first, Grounding.contains(board, CGPoint(x: keyBox.midX, y: keyBox.midY)) {
        region = PlanarTracker.clip(ring, to: keyBox.insetBy(dx: -6 * side, dy: -6 * side).intersection(bounds))
        print("region: the keyboard round the key")
    } else {
        let r = keyBox.insetBy(dx: -2 * side, dy: -2 * side).intersection(bounds)
        region = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        print("region: a patch round the key (no keyboard found)")
    }
    region = region.map { CGPoint(x: $0.x * s, y: $0.y * s) }
    let centre = CGPoint(x: keyBox.midX * s, y: keyBox.midY * s)
    let pitch = Float(keyBox.width * s) * 1.12
    print(String(format: "key: %@ via %@, box %@; pitch %.0f px at tracking size; %d frames", "\(text)", grounded.method, "\(key.box)", pitch, count))

    var base = PlanarTracker()
    guard base.start(image: g0, outline: region) else { fail("too little texture in the region") }

    // The truth: followed frame by frame (taken up again by its corners if lost), and the watch.
    var truth = base
    var truths: [Int: simd_float3x3] = [0: matrix_identity_float3x3]
    var watched = 0, watchAgrees = 0, watchDisagrees = 0, truthLost = 0
    let out = clip.appendingPathComponent("alias")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for n in 1..<count {
        guard let g = grey(n) else { continue }
        if truth.track(g) == .lost {
            truthLost += 1
            guard truth.reacquire(in: g, predicted: truths[n - 1], trustPrediction: false) != nil else { continue }
        }
        truths[n] = truth.homography
        if n % 10 == 0 {
            watched += 1
            if let c = truth.confirmed(in: g) { if c.agrees { watchAgrees += 1 } else { watchDisagrees += 1 } }
        }
        if n % 60 == 0, let c = colour(n) {
            let shown = truth.homography.apply(centre)
            let box = CGRect(x: shown.x / s - keyBox.width / 2, y: shown.y / s - keyBox.height / 2, width: keyBox.width, height: keyBox.height)
            draw(c, outline: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)],
                 to: out.appendingPathComponent(String(format: "truth%04d.jpg", n)))
        }
    }
    print("truth: lost \(truthLost) times; the watch agreed \(watchAgrees), disagreed \(watchDisagrees), could not tell \(watched - watchAgrees - watchDisagrees) of \(watched)")

    // Taken up again from the first frame with shifted predictions.
    let shifts: [Float] = [-2, -1.5, -1, -0.5, 0, 0.5, 1, 1.5, 2]
    var tally: [String: [String: Int]] = ["relocate": [:], "reacquire": [:]]
    var times: [String: [Double]] = ["relocate": [], "reacquire": []]
    for n in stride(from: 30, to: count, by: 30) {
        guard let g = grey(n), let h = truths[n] else { continue }
        let truePoint = h.apply(centre)
        let step = h.apply(CGPoint(x: centre.x + CGFloat(pitch), y: centre.y))
        let pitchHere = Float(hypot(step.x - truePoint.x, step.y - truePoint.y))
        var line = String(format: "frame %3d (key %.0f px):", n, pitchHere)
        for shift in shifts {
            let t = simd_float3x3(rows: [SIMD3(1, 0, shift * pitch), SIMD3(0, 1, 0), SIMD3(0, 0, 1)])
            let predicted = h * t
            for method in ["relocate", "reacquire"] {
                var tracker = base
                let t0 = Date()
                let ok: Bool = method == "relocate" ? tracker.relocate(to: g, predicted: predicted) == .tracking : tracker.reacquire(in: g, predicted: predicted) != nil
                times[method]!.append(Date().timeIntervalSince(t0) * 1000)
                let verdict: String
                if !ok { verdict = "nowhere" } else {
                    let p = tracker.map(centre)
                    let off = Float(hypot(p.x - truePoint.x, p.y - truePoint.y)) / max(pitchHere, 1)
                    verdict = off <= 0.3 ? "right key" : (off > 0.5 ? "look-alike" : "half off")
                }
                tally[method]![verdict, default: 0] += 1
                if method == "reacquire" { line += " " + (verdict == "right key" ? "✓" : verdict == "nowhere" ? "·" : "✗") }
                else { line += verdict == "right key" ? "✓" : verdict == "nowhere" ? "·" : "✗" }
            }
            line += " "
        }
        print(line)
    }
    for method in ["relocate", "reacquire"] {
        let t = tally[method]!, ms = times[method]!.sorted()
        print(String(format: "%@: right key %d, look-alike %d, half off %d, nowhere %d; %.0f ms median", method,
                     t["right key"] ?? 0, t["look-alike"] ?? 0, t["half off"] ?? 0, t["nowhere"] ?? 0, ms.isEmpty ? 0 : ms[ms.count / 2]))
    }
    print("(per frame: for each shift −2 … +2 key widths, relocate then reacquire: ✓ right key, ✗ look-alike or half off, · nowhere)")
}
