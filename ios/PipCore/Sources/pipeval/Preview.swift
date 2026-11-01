import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PipCore
import QuartzCore

// pipeval overlay: draws Pip's cues on frames the iPhone kept (EdgeTAM runs: NNN.jpg, the mask
// NNN.png and NNN.json), the old way and the new way side by side, to judge the design on the Mac.
// The iPhone shows the 3:4 camera image 852 points tall; the previews use the same scale.

enum Preview {
    /// The camera image as the iPhone shows it, in points (sides not cropped).
    static let canvas = CGSize(width: 639, height: 852)

    struct Kept {
        var image: CGImage
        /// The object's outline as the old app drew it (pixel steps, simplified), in points.
        var old: [CGPoint]
        /// The new smooth outline, in points.
        var new: [CGPoint]
    }

    static func load(_ base: URL) -> Kept? {
        guard let src = CGImageSourceCreateWithURL(base.appendingPathExtension("jpg") as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let json = try? JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathExtension("json"))) as? [String: Any],
              let crop = json["crop"] as? [Int], crop.count == 4, crop[2] > 0,
              let maskSrc = CGImageSourceCreateWithURL(base.appendingPathExtension("png") as CFURL, nil),
              let maskImage = CGImageSourceCreateImageAtIndex(maskSrc, 0, nil) else { return nil }
        let w = maskImage.width, h = maskImage.height
        var gray = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(maskImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        let mask = gray.map { $0 > 127 ? UInt8(1) : 0 }
        func toPoints(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (CGFloat(crop[0]) + p.x) / 1024 * canvas.width, y: (CGFloat(crop[1]) + p.y) / 1024 * canvas.height)
        }
        return Kept(image: image, old: EdgeTAM.outline(mask, width: w, height: h).map(toPoints),
                    new: EdgeTAM.contour(mask, width: w, height: h).map(toPoints))
    }

    static func font(_ size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    }

    /// The old app's pointer, as OverlayView drew it until 1 Nov.
    static func oldOutline(_ ring: [CGPoint], pop: CGFloat) -> [CALayer] {
        let path = CGMutablePath()
        path.addLines(between: ring)
        path.closeSubpath()
        let fill = CAShapeLayer()
        fill.path = path
        fill.fillColor = CGColor(srgbRed: 0.25, green: 0.95, blue: 1, alpha: 0.10 + 0.25 * pop)
        fill.strokeColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45)
        fill.lineWidth = 4.5
        fill.lineJoin = .round
        let core = CAShapeLayer()
        core.path = path
        core.fillColor = nil
        core.strokeColor = CGColor(srgbRed: 0.55, green: 1, blue: 1, alpha: 1)
        core.lineWidth = 2
        core.lineJoin = .round
        return [fill, core]
    }

    /// The old step badge: a cyan capsule with black heavy text.
    static func oldBadge(_ text: String, at c: CGPoint) -> [CALayer] {
        let l = CATextLayer()
        l.string = text
        l.font = font(16)
        l.fontSize = 16
        l.alignmentMode = .center
        l.foregroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        l.backgroundColor = CGColor(srgbRed: 0.25, green: 0.95, blue: 1, alpha: 1)
        l.contentsScale = 3
        let w = max(26, CGFloat(text.count) * 9 + 18)
        l.frame = CGRect(x: c.x - w / 2, y: c.y - 13, width: w, height: 26)
        l.cornerRadius = 13
        l.borderColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        l.borderWidth = 1.5
        return [l]
    }

    /// The new pointer for an outline cue with a step label, as OverlayView draws it now.
    static func newOutline(_ ring: [CGPoint], label: String?, progress: CGFloat = 1, pop: CGFloat = 0) -> [CALayer] {
        CueArt.mark([ring], palette: CueArt.action, progress: progress, pop: pop, label: label, font: font(14), scale: 3,
                    view: CGRect(origin: .zero, size: canvas), topInset: 20)
    }

    /// Renders the frame with `layers` on it; `region` (points) and `scale` choose the crop and size.
    static func render(_ image: CGImage, _ layers: [CALayer], region: CGRect, scale: CGFloat) -> CGImage? {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: canvas)
        root.isGeometryFlipped = true
        let bg = CALayer()
        bg.frame = root.bounds
        bg.contents = image
        bg.contentsGravity = .resize
        root.addSublayer(bg)
        layers.forEach { root.addSublayer($0) }
        let w = Int(region.width * scale), h = Int(region.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -region.minX, y: -region.minY)
        root.render(in: ctx)
        // A flipped root renders upside down into a bitmap: turn the result the right way up.
        guard let upsideDown = ctx.makeImage(),
              let out = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        out.translateBy(x: 0, y: CGFloat(h))
        out.scaleBy(x: 1, y: -1)
        out.draw(upsideDown, in: CGRect(x: 0, y: 0, width: w, height: h))
        return out.makeImage()
    }

    /// Images side by side with a thin gap.
    static func sideBySide(_ images: [CGImage]) -> CGImage? {
        let gap = 12
        let w = images.reduce(0) { $0 + $1.width } + gap * (images.count - 1), h = images.map(\.height).max() ?? 0
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var x = 0
        for img in images {
            ctx.draw(img, in: CGRect(x: x, y: h - img.height, width: img.width, height: img.height))
            x += img.width + gap
        }
        return ctx.makeImage()
    }

    static func write(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// For each kept frame: the whole view and a close-up, old (left) against new (right).
    static func run(folder: URL, frames: [Int], out: URL) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for n in frames {
            let base = folder.appendingPathComponent(String(format: "%03d", n))
            guard let k = load(base) else { print("frame \(n): no mask"); continue }
            let old = oldOutline(k.old, pop: 0) + oldBadge("1", at: { let b = Contour.bounds([k.old]); return CGPoint(x: b.midX, y: b.minY - 26) }())
            let new = newOutline(k.new, label: "1")
            let whole = CGRect(origin: .zero, size: canvas)
            let b = Contour.bounds([k.new])
            let side = max(150, max(b.width, b.height) * 2.2)
            let zoom = CGRect(x: b.midX - side / 2, y: b.midY - side / 2 - 12, width: side, height: side)
            let zs = 900 / side
            guard let a = render(k.image, old, region: whole, scale: 1.5), let bImg = render(k.image, new, region: whole, scale: 1.5),
                  let za = render(k.image, oldOutline(k.old, pop: 0) + oldBadge("1", at: CGPoint(x: Contour.bounds([k.old]).midX, y: Contour.bounds([k.old]).minY - 26)), region: zoom, scale: zs),
                  let zb = render(k.image, new, region: zoom, scale: zs) else { continue }
            if let s = sideBySide([a, bImg]) { write(s, to: out.appendingPathComponent(String(format: "%03d-view.png", n))) }
            if let s = sideBySide([za, zb]) { write(s, to: out.appendingPathComponent(String(format: "%03d-zoom.png", n))) }
            // The draw-on, at a quarter, half and three quarters, and a moment later.
            let steps = [0.25, 0.5, 0.75, 1.0].compactMap { p in render(k.image, newOutline(k.new, label: p >= 1 ? "1" : nil, progress: CGFloat(p), pop: CGFloat(1 - p)), region: zoom, scale: 450 / side) }
            if let s = sideBySide(steps) { write(s, to: out.appendingPathComponent(String(format: "%03d-drawon.png", n))) }
            print("frame \(n): old outline \(k.old.count) points, new \(k.new.count) → \(out.path)")
        }
    }

    /// Every kind of cue once, on one frame's object: to judge the whole visual language at once.
    static func sheet(folder: URL, frame n: Int, out: URL) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let k = load(folder.appendingPathComponent(String(format: "%03d", n))) else { print("no mask"); return }
        let b = Contour.bounds([k.new])
        let c = CGPoint(x: b.midX, y: b.midY)
        let side = max(220, max(b.width, b.height) * 3)
        let zoom = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
        let f = font(14)
        let view = CGRect(origin: .zero, size: canvas)
        let small = (0..<24).map { i -> CGPoint in
            let a = Double(i) / 24 * 2 * .pi
            return CGPoint(x: c.x + b.width * 0.3 + 3 * cos(a), y: c.y - 3 + 3 * sin(a))
        }
        let cues: [[CALayer]] = [
            newOutline(k.new, label: nil),
            newOutline(k.new, label: "Stoomknop"),
            CueArt.outline([k.new], palette: CueArt.action, fill: 0, width: 1.5, opacity: 0.8)
                + CueArt.arrow(from: CGPoint(x: c.x, y: b.minY - 10), to: CGPoint(x: c.x, y: b.minY - 10 - max(50, b.height)), palette: CueArt.action, phase: 0.5),
            CueArt.rotation(centre: c, radius: max(26, b.width * 0.6), clockwise: true, palette: CueArt.action),
            CueArt.mark([k.new], palette: CueArt.danger, fill: 0.16, label: "!", filledLabel: true, font: f, scale: 3, view: view, topInset: 20),
            CueArt.mark([k.new], palette: CueArt.verified, fill: 0.1, label: "✓", filledLabel: true, font: f, scale: 3, view: view, topInset: 20),
            CueArt.mark([k.new], palette: CueArt.neutral, fill: 0, dash: CueArt.dots, label: "1", font: f, scale: 3, view: view, topInset: 20),
            CueArt.edgeHint(at: CGPoint(x: zoom.maxX - 30, y: c.y), angle: 0, palette: CueArt.action),
            CueArt.pulse(centre: c, inward: true, palette: CueArt.action, phase: 0.3),
            // A small target (6 points across, like an LED at arm's length) with its step number.
            CueArt.mark([small], palette: CueArt.action, label: "2", font: f, scale: 3, view: view, topInset: 20),
            CueArt.mark([k.new], palette: CueArt.action, dash: CueArt.dashes, font: f, scale: 3, view: view, topInset: 20),
            CueArt.mark([k.new], palette: CueArt.action, progress: 0.55, pop: 0.6, font: f, scale: 3, view: view, topInset: 20),
        ]
        let tiles = cues.compactMap { render(k.image, $0, region: zoom, scale: 420 / side) }
        let rows = stride(from: 0, to: tiles.count, by: 4).compactMap { sideBySide(Array(tiles[$0..<min($0 + 4, tiles.count)])) }
        // The rows stacked, top first.
        let w = rows.map(\.width).max() ?? 0, h = rows.reduce(0) { $0 + $1.height } + 12 * max(0, rows.count - 1)
        guard w > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var top = h
        for row in rows {
            top -= row.height
            ctx.draw(row, in: CGRect(x: 0, y: top, width: row.width, height: row.height))
            top -= 12
        }
        if let img = ctx.makeImage() { write(img, to: out.appendingPathComponent(String(format: "%03d-sheet.png", n))) }
        print("sheet → \(out.path)")
    }
}
