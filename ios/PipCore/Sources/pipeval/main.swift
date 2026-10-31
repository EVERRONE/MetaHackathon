import CoreGraphics
import Foundation
import PipCore

// pipeval: runs Pip's perception on photos through the Worker, on the Mac.
//
//   PIP_URL=… PIP_APP_TOKEN=… pipeval look <image> "<what the user says>" [--prompts a,b] [--lang Dutch] [--goal "…"] [--out dir]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())

// pipeval ground <image> <x> <y> <phrase> [text|alternatives]: grounds one target and times it.
if args.first == "ground", args.count >= 5 {
    let env = ProcessInfo.processInfo.environment
    guard let data = FileManager.default.contents(atPath: args[1]), let frame = SetOfMarks.load(data) else { fail("cannot read \(args[1])") }
    let client = PipClient(baseURL: URL(string: env["PIP_URL"] ?? "https://pip.unveil.be")!, token: env["PIP_APP_TOKEN"] ?? "")
    let spec = TargetSpec(x: Double(args[2])!, y: Double(args[3])!, phrase: args[4], text: args.count > 5 ? args[5].split(separator: "|").map(String.init) : [])
    let t0 = Date()
    let r = await Grounder(client: client).ground(spec, id: 1, frame: frame, frameJPEG: SetOfMarks.jpeg(frame)!)
    print(String(format: "%.2fs", Date().timeIntervalSince(t0)), r.method, r.instance.map { "box \($0.box) conf \($0.confidence)" } ?? "nil")
    exit(0)
}

// pipeval listen <16 kHz wav>: streams it through the live transcription relay at real-time pace.
if args.first == "listen", args.count >= 2 {
    let env = ProcessInfo.processInfo.environment
    guard let wav = FileManager.default.contents(atPath: args[1]) else { fail("cannot read \(args[1])") }
    let asr = RealtimeTranscriber(baseURL: URL(string: env["PIP_URL"] ?? "https://pip.unveil.be")!, token: env["PIP_APP_TOKEN"] ?? "")
    let t0 = Date()
    asr.connect()
    let pcm = wav.dropFirst(44)
    Task {
        try? await Task.sleep(nanoseconds: 300_000_000)
        let frame = 2560 // 80 ms at 16 kHz
        var o = pcm.startIndex
        while o < pcm.endIndex {
            asr.send(pcm: Data(pcm[o..<min(o + frame, pcm.endIndex)]))
            o += frame
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        print(String(format: "%5.2fs end of audio", Date().timeIntervalSince(t0)))
        // Live, the microphone keeps sending (near) silence; endpointing decides when the turn ends.
        for _ in 0..<100 { asr.send(pcm: Data(count: frame)); try? await Task.sleep(nanoseconds: 80_000_000) }
        asr.finish()
    }
    for await e in asr.events {
        print(String(format: "%5.2fs", Date().timeIntervalSince(t0)), e)
        if case .final = e { break }
        if case .closed = e { break }
    }
    asr.close()
    exit(0)
}

guard args.first == "look", args.count >= 3 else {
    fail("usage: pipeval look <image> \"<utterance>\" [--prompts a,b] [--lang English|Dutch] [--goal \"…\"] [--out dir]")
}
args.removeFirst()
let imagePath = args.removeFirst()
let utterance = args.removeFirst()
var options: [String: String] = [:]
while args.count >= 2, args[0].hasPrefix("--") {
    options[String(args[0].dropFirst(2))] = args[1]
    args.removeFirst(2)
}

let env = ProcessInfo.processInfo.environment
guard let token = env["PIP_APP_TOKEN"] else { fail("PIP_APP_TOKEN is not set") }
let base = URL(string: env["PIP_URL"] ?? "https://pip.unveil.be")!
guard let data = FileManager.default.contents(atPath: imagePath), let frame = SetOfMarks.load(data) else { fail("cannot read \(imagePath)") }

let client = PipClient(baseURL: base, token: token)
let pipeline = LookPipeline(client: client, language: options["lang"] ?? "English")
let request = LookRequest(
    frame: frame,
    prompts: options["prompts"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } },
    goal: options["goal"],
    utterance: utterance
)
let outDir = URL(fileURLWithPath: options["out"] ?? FileManager.default.currentDirectoryPath)

func word(at anchor: Int, in text: String) -> String {
    let u = Array(text.utf16)
    var e = anchor
    while e < u.count, let s = Unicode.Scalar(u[e]), CharacterSet.alphanumerics.contains(s) { e += 1 }
    return String(decoding: u[anchor..<e], as: UTF16.self)
}

let start = Date()
func stamp() -> String { String(format: "%5.2fs", Date().timeIntervalSince(start)) }

var instances: [SegmentInstance] = []
var shown: [Cue] = []
do {
    for try await event in pipeline.run(request) {
        switch event {
        case .target(let id, let spec):
            print("\(stamp())  🎯 target \(id): \(spec.phrase) \(spec.text) @\(Int(spec.x)),\(Int(spec.y))")
        case .grounded(let id, let inst, let method, let seconds):
            if let inst { instances.append(inst) }
            print("\(stamp())  📍 target \(id) → " + (inst.map { "box \($0.box) conf \(String(format: "%.2f", $0.confidence))" } ?? "not found") + " via \(method) in \(String(format: "%.2f", seconds))s")
        case .segmented(let s, let marked):
            instances = s.instances
            print("\(stamp())  segmented: \(s.instances.count) marks · \(s.calls.map { "\($0.prompt)=\($0.found) in \($0.ms) ms" }.joined(separator: ", "))")
            try? marked.write(to: outDir.appendingPathComponent("marked.jpg"))
        case .sentence(let sentence, let traces):
            print("\(stamp())  🗣  \(sentence.text)")
            for t in traces {
                switch t.decision {
                case .accept(let c): print("           ✓ \(t.raw) → \(c)")
                case .downgrade(let c, let why): print("           ↓ \(t.raw) → \(c) (\(why))")
                case .reject(let why): print("           ✗ \(t.raw) (\(why))")
                }
            }
            for c in sentence.cues { print("           ⏱ \(c.cue) on \"\(word(at: c.anchor, in: sentence.text))\""); shown.append(c.cue) }
        case .sideChannel(let cue):
            print("\(stamp())  ⚙︎  \(cue)")
        case .invalidTag(let err):
            print("\(stamp())  ✗ invalid tag \(err)")
        case .finished(let s):
            let fmt = { (x: Double?) in x.map { String(format: "%.2fs", $0) } ?? "–" }
            print("\(stamp())  done · first token \(fmt(s.firstTokenSeconds)) · first sentence \(fmt(s.firstSentenceSeconds)) · total \(fmt(s.totalSeconds))")
            if let u = s.usage { print("        tokens: prompt \(u.promptTokens) (cached \(u.promptTokensDetails?.cachedTokens ?? 0)), completion \(u.completionTokens)") }
        }
    }
} catch {
    fail("look failed: \(error)")
}

// Draw what the user would see: the validated cues on their marks.
if let ctx = CGContext(data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
    ctx.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
    ctx.translateBy(x: 0, y: CGFloat(frame.height))
    ctx.scaleBy(x: 1, y: -1)
    let byId = Dictionary(uniqueKeysWithValues: instances.map { ($0.id, $0) })
    for cue in shown {
        let color: CGColor
        var dash: [CGFloat] = []
        switch cue {
        case .danger: color = CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1)
        case .verified: color = CGColor(red: 0.2, green: 0.9, blue: 0.3, alpha: 1)
        case .candidates, .place: color = CGColor(red: 1, green: 1, blue: 1, alpha: 1); dash = [10, 6]
        default: color = CGColor(red: 0.2, green: 1, blue: 1, alpha: 1)
        }
        for m in cue.marks {
            guard let inst = byId[m] else { continue }
            for ring in inst.outlinePoints where ring.count >= 3 {
                ctx.setLineDash(phase: 0, lengths: dash)
                ctx.addLines(between: ring)
                ctx.closePath()
                ctx.setStrokeColor(color)
                ctx.setLineWidth(5)
                ctx.strokePath()
            }
            if case .move(_, let dir) = cue {
                let c = inst.centre
                let len = max(inst.boxRect.height, inst.boxRect.width) * 0.6
                let (dx, dy): (CGFloat, CGFloat) = switch dir {
                case .up: (0, -1)
                case .down: (0, 1)
                case .left: (-1, 0)
                case .right: (1, 0)
                case .in, .out: (0, 0)
                }
                let tip = CGPoint(x: c.x + dx * len, y: c.y + dy * len)
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.move(to: c)
                ctx.addLine(to: tip)
                ctx.setLineWidth(8)
                ctx.strokePath()
                ctx.move(to: tip)
                ctx.addLine(to: CGPoint(x: tip.x - dx * 25 - dy * 18, y: tip.y - dy * 25 - dx * 18))
                ctx.addLine(to: CGPoint(x: tip.x - dx * 25 + dy * 18, y: tip.y - dy * 25 + dx * 18))
                ctx.closePath()
                ctx.setFillColor(color)
                ctx.fillPath()
            }
        }
    }
    if let img = ctx.makeImage(), let jpg = SetOfMarks.jpeg(img) {
        try? jpg.write(to: outDir.appendingPathComponent("cues.jpg"))
    }
}
