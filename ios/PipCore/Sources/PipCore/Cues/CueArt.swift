import CoreGraphics
import CoreText
import Foundation
import QuartzCore

/// How Pip's cues look: one visual language for every cue. An object is marked by a crisp light
/// line just outside its edge, a thin dark rim (readable on any background), a soft glow in the
/// cue's colour and a faint tint inside; the line draws itself on round the object when the cue
/// appears. A small target gets a fine ring with four ticks around it; labels are small dark chips
/// on a leader line, above the object rather than on it. Shared by the app's overlay and pipeval's
/// previews, so what is judged on the Mac is what the iPhone draws.
public enum CueArt {
    public struct Palette {
        /// The crisp line: the cue colour, lightened.
        public var line: CGColor
        /// The glow, the tint and chip borders: the cue colour itself.
        public var glow: CGColor
    }

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
    }

    public static let action = Palette(line: rgb(0.84, 1, 1), glow: rgb(0.2, 0.9, 1))
    public static let danger = Palette(line: rgb(1, 0.84, 0.82), glow: rgb(1, 0.27, 0.23))
    public static let verified = Palette(line: rgb(0.86, 1, 0.88), glow: rgb(0.2, 0.85, 0.35))
    public static let neutral = Palette(line: rgb(1, 1, 1), glow: rgb(0.78, 0.84, 0.95))

    static func faded(_ c: CGColor, _ alpha: CGFloat) -> CGColor { c.copy(alpha: alpha) ?? c }

    static let rim = rgb(0, 0, 0, 0.4)
    static let chipFill = rgb(0.06, 0.07, 0.09, 0.84)
    static let white = rgb(1, 1, 1)

    /// How long an outline takes to draw itself on.
    public static let drawOn: Double = 0.5

    /// Eases the draw-on: fast start, gentle landing.
    public static func progress(since shown: Double, now: Double) -> CGFloat {
        let t = min(max((now - shown) / drawOn, 0), 1)
        return CGFloat(1 - pow(1 - t, 3))
    }

    /// 1 when a cue appears, settling to 0 over about 0.8 s.
    public static func pop(since shown: Double, now: Double) -> CGFloat {
        CGFloat(exp(-max(0, now - shown) * 4))
    }

    // MARK: A marked object

    /// Below this size on screen (points) an object also gets a reticle round it.
    public static let smallTarget: CGFloat = 28

    public static func reticleRadius(_ rect: CGRect) -> CGFloat { max(14, max(rect.width, rect.height) / 2 + 9) }

    /// Everything that marks one object: its outline, a reticle when it is small on screen, and a
    /// label on a leader line when there is one. `view`: the screen; `topInset`: room kept free at
    /// the top (status and captions).
    public static func mark(_ rings: [[CGPoint]], palette: Palette, progress: CGFloat = 1, pop: CGFloat = 0, fill: CGFloat = 0.08,
                            width: CGFloat = 2, dash: [CGFloat]? = nil, opacity: CGFloat = 1, label: String? = nil, filledLabel: Bool = false,
                            font: CTFont, scale: CGFloat, view: CGRect, topInset: CGFloat) -> [CALayer] {
        var layers = outline(rings, palette: palette, progress: progress, pop: pop, fill: fill, width: width, dash: dash, opacity: opacity)
        let b = Contour.bounds(rings)
        guard !b.isNull else { return layers }
        let small = max(b.width, b.height) < smallTarget
        if small { layers += reticle(around: b, palette: palette, progress: progress, pop: pop, opacity: opacity) }
        if let label, progress > 0.6 {
            let appear = min(1, (progress - 0.6) / 0.4) * opacity
            let size = chipSize(label, font: font)
            let r = reticleRadius(b)
            let target = small ? CGRect(x: b.midX - r, y: b.midY - r, width: 2 * r, height: 2 * r) : b
            let chipCentre = labelPlacement(for: target, in: view, chipHeight: size.height, topInset: topInset)
            let edge = CGPoint(x: chipCentre.x, y: chipCentre.y + (chipCentre.y < target.midY ? size.height / 2 : -size.height / 2))
            let anchor: CGPoint
            if small {
                let dx = edge.x - b.midX, dy = edge.y - b.midY, d = max(hypot(dx, dy), 1e-6)
                anchor = CGPoint(x: b.midX + dx / d * r, y: b.midY + dy / d * r)
            } else {
                // On the drawn line, which lies just outside the object's edge: straight below (or
                // above) the label where the object is there, else the nearest point of it.
                let above = chipCentre.y < target.midY
                let q = Contour.verticalHit(on: rings, x: edge.x, fromTop: above) ?? Contour.nearestPoint(on: rings, to: edge) ?? CGPoint(x: b.midX, y: b.minY)
                let dx = edge.x - q.x, dy = edge.y - q.y, d = max(hypot(dx, dy), 1e-6)
                anchor = CGPoint(x: q.x + dx / d * (width / 2 + 0.75), y: q.y + dy / d * (width / 2 + 0.75))
            }
            if hypot(edge.x - anchor.x, edge.y - anchor.y) > 4 { layers += leader(from: anchor, to: edge, palette: palette, opacity: appear) }
            layers += chip(label, centre: chipCentre, palette: palette, font: font, scale: scale, filled: filledLabel, opacity: appear)
        }
        return layers
    }

    // MARK: Outlines

    /// A marked object (`rings` in screen points). `progress` < 1 draws that much of each ring.
    public static func outline(_ rings: [[CGPoint]], palette: Palette, progress: CGFloat = 1, pop: CGFloat = 0,
                               fill: CGFloat = 0.08, width: CGFloat = 2, dash: [CGFloat]? = nil, opacity: CGFloat = 1) -> [CALayer] {
        let shapes = rings.filter { $0.count >= 3 }.map { Contour.display($0, spacing: 3, outset: width / 2 + 0.75) }
        guard !shapes.isEmpty else { return [] }
        var layers: [CALayer] = []
        if fill > 0 {
            let closed = CGMutablePath()
            shapes.forEach { closed.addPath(Contour.path($0)) }
            let tint = CAShapeLayer()
            tint.path = closed
            tint.fillColor = faded(palette.glow, min(0.35, (fill + 0.14 * pop) * progress))
            tint.strokeColor = nil
            layers.append(tint)
        }
        let path = CGMutablePath()
        shapes.forEach { path.addPath(Contour.path($0, upTo: progress)) }
        layers += strokes(path, palette: palette, width: width, glow: 0.5 + 0.5 * pop, dash: dash)
        // The head of a line drawing on: a small bright point leading it.
        if progress < 1, dash == nil {
            for s in shapes {
                guard let head = Contour.point(s, at: progress) else { continue }
                layers.append(dot(head, radius: width * 1.25, palette: palette))
            }
        }
        layers.forEach { $0.opacity *= Float(opacity) }
        return layers
    }

    /// A small target (a key, an LED, a screw): a fine ring with four ticks around it, so it is easy
    /// to find on screen however small it is; the outline itself stays visible inside.
    public static func reticle(around rect: CGRect, palette: Palette, progress: CGFloat = 1, pop: CGFloat = 0, opacity: CGFloat = 1) -> [CALayer] {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = reticleRadius(rect)
        let ring = CGMutablePath()
        let start = -CGFloat.pi / 2
        ring.addArc(center: c, radius: r, startAngle: start, endAngle: start + 2 * .pi * max(0.001, progress), clockwise: false)
        if progress > 0.5 {
            let tick = min(1, (progress - 0.5) * 2) * 6
            for k in 0..<4 {
                let a = CGFloat(k) * .pi / 2
                ring.move(to: CGPoint(x: c.x + cos(a) * (r + 3), y: c.y + sin(a) * (r + 3)))
                ring.addLine(to: CGPoint(x: c.x + cos(a) * (r + 3 + tick), y: c.y + sin(a) * (r + 3 + tick)))
            }
        }
        let layers = strokes(ring, palette: palette, width: 1.75, glow: 0.45 + 0.55 * pop)
        layers.forEach { $0.opacity *= Float(opacity) }
        return layers
    }

    // MARK: Actions

    /// "Push, pull or slide it this way": an arrow that nudges gently in its direction. `phase`
    /// runs 0…1 and repeats (about 1.4 s).
    public static func arrow(from a: CGPoint, to b: CGPoint, palette: Palette, phase: CGFloat = 0, opacity: CGFloat = 1) -> [CALayer] {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(1, hypot(dx, dy))
        let ux = dx / len, uy = dy / len
        let nudge = 6 * (0.5 - 0.5 * cos(2 * .pi * phase))
        let s = CGPoint(x: a.x + ux * nudge, y: a.y + uy * nudge)
        let e = CGPoint(x: b.x + ux * nudge, y: b.y + uy * nudge)
        let head = min(16, len * 0.35)
        let path = CGMutablePath()
        path.move(to: s)
        path.addLine(to: e)
        // A chevron head, opened 40° each side.
        let ca = cos(0.7), sa = sin(0.7)
        path.move(to: CGPoint(x: e.x - head * (ux * ca - uy * sa), y: e.y - head * (uy * ca + ux * sa)))
        path.addLine(to: e)
        path.addLine(to: CGPoint(x: e.x - head * (ux * ca + uy * sa), y: e.y - head * (uy * ca - ux * sa)))
        let layers = strokes(path, palette: palette, width: 4, glow: 0.7)
        layers.forEach { $0.opacity *= Float(opacity) }
        return layers
    }

    /// "Turn it": three quarters of a circle with a chevron head at its end.
    public static func rotation(centre c: CGPoint, radius r: CGFloat, clockwise: Bool, palette: Palette, progress: CGFloat = 1, opacity: CGFloat = 1) -> [CALayer] {
        let start: CGFloat = -.pi * 0.9
        let sweep: CGFloat = .pi * 1.5 * max(0.05, progress)
        let end = start + sweep * (clockwise ? 1 : -1)
        let path = CGMutablePath()
        // CoreGraphics' "clockwise" is with y up; on a screen (y down) it is the other way round.
        path.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: !clockwise)
        let tip = CGPoint(x: c.x + r * cos(end), y: c.y + r * sin(end))
        let t: CGFloat = clockwise ? 1 : -1
        let ux = -sin(end) * t, uy = cos(end) * t
        let head: CGFloat = 12
        let ca = cos(0.7), sa = sin(0.7)
        path.move(to: CGPoint(x: tip.x - head * (ux * ca - uy * sa), y: tip.y - head * (uy * ca + ux * sa)))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x - head * (ux * ca + uy * sa), y: tip.y - head * (uy * ca - ux * sa)))
        let layers = strokes(path, palette: palette, width: 3.5, glow: 0.7)
        layers.forEach { $0.opacity *= Float(opacity) }
        return layers
    }

    /// Dots along the outline: look-alikes Pip cannot tell apart.
    public static let dots: [CGFloat] = [0.01, 6]
    /// Dashes: where something must go.
    public static let dashes: [CGFloat] = [9, 7]

    /// "Push it in" or "pull it out": rings that close in on the spot, or open out from it, again
    /// and again. `phase` runs 0…1 and repeats (about 1.2 s).
    public static func pulse(centre c: CGPoint, inward: Bool, palette: Palette, phase: CGFloat, opacity: CGFloat = 1) -> [CALayer] {
        var layers: [CALayer] = []
        for k in 0..<2 {
            let t = (phase + CGFloat(k) * 0.5).truncatingRemainder(dividingBy: 1)
            let s = inward ? 1 - t : t
            let r = 10 + 22 * s
            let path = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
            let ring = strokes(path, palette: palette, width: 2, glow: 0.6)
            // Fades in at the start of its way and out at the end.
            let a = sin(.pi * t)
            ring.forEach { $0.opacity = Float(a * opacity) }
            layers += ring
        }
        layers.append(dot(c, radius: 3, palette: palette))
        return layers
    }

    /// The way to a mark out of view: a dark round button at the screen edge with a chevron
    /// pointing at it (`angle` in radians, screen axes, 0 = right).
    public static func edgeHint(at p: CGPoint, angle: CGFloat, palette: Palette, opacity: CGFloat = 1) -> [CALayer] {
        let r: CGFloat = 19
        let disc = CAShapeLayer()
        let circle = CGPath(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r), transform: nil)
        disc.path = circle
        disc.fillColor = chipFill
        disc.strokeColor = palette.glow
        disc.lineWidth = 1.5
        disc.shadowColor = palette.glow
        disc.shadowOpacity = 0.6
        disc.shadowRadius = 6
        disc.shadowOffset = .zero
        disc.shadowPath = circle
        let ux = cos(angle), uy = sin(angle)
        let tip = CGPoint(x: p.x + ux * 6, y: p.y + uy * 6)
        let chevron = CGMutablePath()
        let ca = cos(0.8), sa = sin(0.8), h: CGFloat = 10
        chevron.move(to: CGPoint(x: tip.x - h * (ux * ca - uy * sa), y: tip.y - h * (uy * ca + ux * sa)))
        chevron.addLine(to: tip)
        chevron.addLine(to: CGPoint(x: tip.x - h * (ux * ca + uy * sa), y: tip.y - h * (uy * ca - ux * sa)))
        let mark = CAShapeLayer()
        mark.path = chevron
        mark.strokeColor = palette.line
        mark.fillColor = nil
        mark.lineWidth = 3
        mark.lineCap = .round
        mark.lineJoin = .round
        let layers: [CALayer] = [disc, mark]
        layers.forEach { $0.opacity = Float(opacity) }
        return layers
    }

    // MARK: Labels

    /// A label: white text on a small dark chip with a border in the cue colour (`filled`: on the
    /// cue colour itself, for "!" and "✓"). One character makes a round chip.
    public static func chip(_ text: String, centre: CGPoint, palette: Palette, font: CTFont, scale: CGFloat,
                            filled: Bool = false, opacity: CGFloat = 1) -> [CALayer] {
        let size = chipSize(text, font: font)
        let frame = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
        let bg = CALayer()
        bg.frame = frame
        bg.cornerRadius = size.height / 2
        bg.backgroundColor = filled ? palette.glow : chipFill
        bg.borderColor = filled ? faded(white, 0.9) : palette.glow
        bg.borderWidth = filled ? 1.25 : 1.25
        bg.shadowColor = rgb(0, 0, 0)
        bg.shadowOpacity = 0.35
        bg.shadowRadius = 4
        bg.shadowOffset = CGSize(width: 0, height: 1)
        bg.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil)
        let label = CATextLayer()
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let lineHeight = ceil(ascent + descent)
        label.frame = CGRect(x: frame.minX, y: frame.midY - lineHeight / 2, width: frame.width, height: lineHeight)
        label.string = text
        label.font = font
        label.fontSize = CTFontGetSize(font)
        label.foregroundColor = filled ? rgb(0.02, 0.03, 0.04) : white
        label.alignmentMode = .center
        label.contentsScale = scale
        label.truncationMode = .end
        let layers: [CALayer] = [bg, label]
        layers.forEach { $0.opacity = Float(opacity) }
        return layers
    }

    public static func chipSize(_ text: String, font: CTFont) -> CGSize {
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let height = ceil(CTFontGetSize(font) * 1.75)
        return CGSize(width: max(height, ceil(width) + (text.count <= 1 ? 0 : 18)), height: height)
    }

    /// A fine line from the object's edge (a dot there) to its label.
    public static func leader(from a: CGPoint, to b: CGPoint, palette: Palette, opacity: CGFloat = 1) -> [CALayer] {
        let path = CGMutablePath()
        path.move(to: a)
        path.addLine(to: b)
        let under = CAShapeLayer()
        under.path = path
        under.strokeColor = rim
        under.lineWidth = 3
        under.lineCap = .round
        let line = CAShapeLayer()
        line.path = path
        line.strokeColor = faded(palette.line, 0.95)
        line.lineWidth = 1.25
        line.lineCap = .round
        let layers: [CALayer] = [under, line, dot(a, radius: 2.5, palette: palette)]
        layers.forEach { $0.opacity *= Float(opacity) }
        return layers
    }

    /// Where a label goes for an object with screen bounds `b`: centred above it, or below it when
    /// there is no room above. Returns the chip's centre (its leader is drawn from the outline).
    public static func labelPlacement(for b: CGRect, in view: CGRect, chipHeight: CGFloat, topInset: CGFloat) -> CGPoint {
        let gap: CGFloat = 16
        let above = b.minY - gap - chipHeight / 2
        let x = min(max(b.midX, view.minX + 40), view.maxX - 40)
        if above - chipHeight / 2 > topInset { return CGPoint(x: x, y: above) }
        return CGPoint(x: x, y: b.maxY + gap + chipHeight / 2)
    }

    // MARK: Strokes

    /// Glow, dark rim and crisp line, bottom to top.
    static func strokes(_ path: CGPath, palette: Palette, width: CGFloat, glow: CGFloat, dash: [CGFloat]? = nil) -> [CALayer] {
        func layer(_ color: CGColor, _ w: CGFloat) -> CAShapeLayer {
            let l = CAShapeLayer()
            l.path = path
            l.strokeColor = color
            l.fillColor = nil
            l.lineWidth = w
            l.lineCap = .round
            l.lineJoin = .round
            l.lineDashPattern = dash?.map { NSNumber(value: Double($0)) }
            return l
        }
        let halo = layer(faded(palette.glow, 0.85), width + 1)
        halo.shadowColor = palette.glow
        halo.shadowOpacity = Float(min(1, glow))
        halo.shadowRadius = 7
        halo.shadowOffset = .zero
        // An explicit shadow shape: Core Animation then needs no offscreen pass to find it.
        halo.shadowPath = path.copy(strokingWithWidth: width + 3, lineCap: .round, lineJoin: .round, miterLimit: 4)
        return [halo, layer(rim, width + 2), layer(palette.line, width)]
    }

    static func dot(_ p: CGPoint, radius r: CGFloat, palette: Palette) -> CALayer {
        let l = CAShapeLayer()
        let circle = CGPath(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r), transform: nil)
        l.path = circle
        l.fillColor = palette.line
        l.strokeColor = rim
        l.lineWidth = 1
        l.shadowColor = palette.glow
        l.shadowOpacity = 0.9
        l.shadowRadius = 5
        l.shadowOffset = .zero
        l.shadowPath = circle
        return l
    }
}
