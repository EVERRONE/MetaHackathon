// Draws Pip's app icon and launch mark: a white dot inside an open, glowing ring, the way Pip
// rings the thing to touch (CueArt.action's colours). Run from ios/:
//   swift scripts/make-brand.swift
// Writes PipApp/Assets.xcassets (AppIcon, LaunchMark, LaunchBackground) and docs/pip-icon.png.
import AppKit
import CoreGraphics
import Foundation

let line = CGColor(red: 0.84, green: 1, blue: 1, alpha: 1)        // CueArt.action.line
let glow = CGColor(red: 0.2, green: 0.9, blue: 1, alpha: 1)       // CueArt.action.glow
let dot = CGColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1)
let night = (r: 0.051, g: 0.071, b: 0.125)                        // the launch background
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func canvas(_ w: Int, _ h: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

func save(_ ctx: CGContext, _ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote", path)
}

/// The mark: an open ring (its gap at the upper right, as if closing round the thing) and the dot.
func mark(_ ctx: CGContext, centre c: CGPoint, radius r: CGFloat) {
    let width = r * 0.23
    let gap: CGFloat = 46 * .pi / 180, at: CGFloat = 45 * .pi / 180
    let ring = CGMutablePath()
    ring.addArc(center: c, radius: r, startAngle: at + gap / 2, endAngle: at - gap / 2 + 2 * .pi, clockwise: false)
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(width)
    // The glow, then the line on it.
    ctx.setShadow(offset: .zero, blur: r * 0.22, color: glow)
    ctx.setStrokeColor(glow)
    ctx.addPath(ring)
    ctx.strokePath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setStrokeColor(line)
    ctx.setLineWidth(width * 0.78)
    ctx.addPath(ring)
    ctx.strokePath()
    // The thing to touch.
    let d = r * 0.36
    ctx.setShadow(offset: .zero, blur: r * 0.12, color: glow.copy(alpha: 0.55))
    ctx.setFillColor(dot)
    ctx.fillEllipse(in: CGRect(x: c.x - d, y: c.y - d, width: 2 * d, height: 2 * d))
    ctx.restoreGState()
}

func text(_ ctx: CGContext, _ s: String, size: CGFloat, weight: NSFont.Weight, rounded: Bool, tracking: CGFloat, alpha: CGFloat, centreX: CGFloat, baseline y: CGFloat) {
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if rounded, let d = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: d, size: size) ?? font }
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: tracking, .foregroundColor: NSColor(calibratedWhite: 1, alpha: alpha)]
    let str = NSAttributedString(string: s, attributes: attrs)
    let lineRef = CTLineCreateWithAttributedString(str)
    let width = CTLineGetTypographicBounds(lineRef, nil, nil, nil)
    ctx.textPosition = CGPoint(x: centreX - CGFloat(width) / 2, y: y)
    CTLineDraw(lineRef, ctx)
}

// The app icon: 1024 × 1024 on a deep night-blue field (iOS rounds the corners).
let icon = canvas(1024, 1024)
let colours = [CGColor(red: 0.085, green: 0.12, blue: 0.2, alpha: 1), CGColor(red: 0.027, green: 0.039, blue: 0.075, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: space, colors: colours, locations: [0, 1])!
icon.drawRadialGradient(gradient, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 760, options: [.drawsAfterEndLocation])
mark(icon, centre: CGPoint(x: 512, y: 512), radius: 272)
save(icon, "PipApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
save(icon, "../docs/pip-icon.png")

// The launch mark: the mark, "Pip" and "Personal Interactive Partner", on a clear field (the
// launch background colour shows through), 300 × 380 points, at 2× and 3×.
for scale in [2, 3] {
    let s = CGFloat(scale)
    let ctx = canvas(300 * scale, 380 * scale)
    mark(ctx, centre: CGPoint(x: 150 * s, y: 255 * s), radius: 62 * s)
    text(ctx, "Pip", size: 50 * s, weight: .bold, rounded: true, tracking: 0.5 * s, alpha: 1, centreX: 150 * s, baseline: 105 * s)
    text(ctx, "PERSONAL INTERACTIVE PARTNER", size: 12.5 * s, weight: .semibold, rounded: false, tracking: 2.4 * s, alpha: 0.62, centreX: 150 * s, baseline: 72 * s)
    save(ctx, "PipApp/Assets.xcassets/LaunchMark.imageset/LaunchMark@\(scale)x.png")
}

// The asset catalog's descriptions.
func write(_ json: String, _ path: String) {
    try! json.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
}
write(#"{ "info" : { "author" : "xcode", "version" : 1 } }"#, "PipApp/Assets.xcassets/Contents.json")
write(#"""
{
  "images" : [ { "filename" : "AppIcon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""#, "PipApp/Assets.xcassets/AppIcon.appiconset/Contents.json")
write(#"""
{
  "images" : [
    { "idiom" : "universal", "scale" : "1x" },
    { "filename" : "LaunchMark@2x.png", "idiom" : "universal", "scale" : "2x" },
    { "filename" : "LaunchMark@3x.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""#, "PipApp/Assets.xcassets/LaunchMark.imageset/Contents.json")
try! FileManager.default.createDirectory(atPath: "PipApp/Assets.xcassets/LaunchBackground.colorset", withIntermediateDirectories: true)
write("""
{
  "colors" : [ { "color" : { "color-space" : "srgb", "components" : { "alpha" : "1.000", "red" : "\(String(format: "%.3f", night.r))", "green" : "\(String(format: "%.3f", night.g))", "blue" : "\(String(format: "%.3f", night.b))" } }, "idiom" : "universal" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""", "PipApp/Assets.xcassets/LaunchBackground.colorset/Contents.json")
