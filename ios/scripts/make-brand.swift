// Draws Pip's app icon and launch mark: a dot inside an open ring, the way Pip rings the thing to
// touch, flat, in the manner of today's App Store icons: one confident colour field, one white
// mark, no glow (iOS adds its own glass), the mark about 57 % of the field. Signal cyan is the
// colour Pip points with in the camera view. Run from ios/:
//   swift scripts/make-brand.swift
// Writes PipApp/Assets.xcassets (AppIcon with its dark and tinted variants, LaunchMark,
// LaunchBackground) and docs/pip-icon.png for the README.
import AppKit
import CoreGraphics
import Foundation

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
let cyanTop = rgb(0x2CD3EA), cyanBottom = rgb(0x0A8BB5)      // the light field
let inkTop = rgb(0x23262B), inkBottom = rgb(0x0C0D0F)        // the dark field
let cyan = rgb(0x34D6EC)                                      // the ring on dark
let white = rgb(0xFFFFFF)
let launchField: (r: Double, g: Double, b: Double) = (0.055, 0.063, 0.075)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// `opaque`: no alpha channel (app icons must have none).
func canvas(_ w: Int, _ h: Int, opaque: Bool) -> CGContext {
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
    ctx.setShouldAntialias(true)
    return ctx
}

func save(_ ctx: CGContext, _ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote", path)
}

/// The mark: an open ring, its gap at the upper right (as if closing round the thing), and the dot.
func mark(_ ctx: CGContext, centre c: CGPoint, radius r: CGFloat, ring: CGColor, dot: CGColor) {
    let gap: CGFloat = 52 * .pi / 180, at: CGFloat = 45 * .pi / 180
    let path = CGMutablePath()
    path.addArc(center: c, radius: r, startAngle: at + gap / 2, endAngle: at - gap / 2 + 2 * .pi, clockwise: false)
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(r * 0.44)
    ctx.setStrokeColor(ring)
    ctx.addPath(path)
    ctx.strokePath()
    let d = r * 0.36
    ctx.setFillColor(dot)
    ctx.fillEllipse(in: CGRect(x: c.x - d, y: c.y - d, width: 2 * d, height: 2 * d))
    ctx.restoreGState()
}

/// A 1024 × 1024 icon: the field (a vertical gradient, lighter at the top) and the mark.
func icon(top: CGColor, bottom: CGColor, ring: CGColor, dot: CGColor, squircle: Bool = false) -> CGContext {
    let ctx = canvas(1024, 1024, opaque: !squircle)
    if squircle {
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 1024, height: 1024), cornerWidth: 229, cornerHeight: 229, transform: nil))
        ctx.clip()
    }
    let g = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])
    mark(ctx, centre: CGPoint(x: 512, y: 512), radius: 241, ring: ring, dot: dot)
    return ctx
}

func text(_ ctx: CGContext, _ s: String, size: CGFloat, weight: NSFont.Weight, rounded: Bool, tracking: CGFloat, alpha: CGFloat, centreX: CGFloat, baseline y: CGFloat) {
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if rounded, let d = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: d, size: size) ?? font }
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: tracking, .foregroundColor: NSColor(calibratedWhite: 1, alpha: alpha)]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textPosition = CGPoint(x: centreX - CGFloat(width) / 2, y: y)
    CTLineDraw(line, ctx)
}

let set = "PipApp/Assets.xcassets/AppIcon.appiconset"
// Light: the white mark on signal cyan. Dark: the cyan ring and a white dot on ink. Tinted: grey
// tones on black, which iOS colours with the user's tint.
save(icon(top: cyanTop, bottom: cyanBottom, ring: white, dot: white), "\(set)/AppIcon.png")
save(icon(top: inkTop, bottom: inkBottom, ring: cyan, dot: white), "\(set)/AppIcon-Dark.png")
save(icon(top: rgb(0x000000), bottom: rgb(0x000000), ring: rgb(0xFFFFFF), dot: rgb(0xD0D0D0)), "\(set)/AppIcon-Tinted.png")
// For the README: the light icon in its rounded shape.
save(icon(top: cyanTop, bottom: cyanBottom, ring: white, dot: white, squircle: true), "../docs/pip-icon.png")

// The launch mark on a clear field (the launch background shows through), 300 × 380 points at 2×
// and 3×: the dark icon's mark, "Pip" and "Personal Interactive Partner". Dark, as the camera view
// that follows it.
for scale in [2, 3] {
    let s = CGFloat(scale)
    let ctx = canvas(300 * scale, 380 * scale, opaque: false)
    mark(ctx, centre: CGPoint(x: 150 * s, y: 255 * s), radius: 58 * s, ring: cyan, dot: white)
    text(ctx, "Pip", size: 50 * s, weight: .bold, rounded: true, tracking: 0.5 * s, alpha: 1, centreX: 150 * s, baseline: 105 * s)
    text(ctx, "PERSONAL INTERACTIVE PARTNER", size: 12.5 * s, weight: .semibold, rounded: false, tracking: 2.4 * s, alpha: 0.6, centreX: 150 * s, baseline: 72 * s)
    save(ctx, "PipApp/Assets.xcassets/LaunchMark.imageset/LaunchMark@\(scale)x.png")
}

func write(_ json: String, _ path: String) {
    try! json.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
}
write(#"{ "info" : { "author" : "xcode", "version" : 1 } }"#, "PipApp/Assets.xcassets/Contents.json")
write(#"""
{
  "images" : [
    { "filename" : "AppIcon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "AppIcon-Dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ], "filename" : "AppIcon-Tinted.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""#, "\(set)/Contents.json")
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
  "colors" : [ { "color" : { "color-space" : "srgb", "components" : { "alpha" : "1.000", "red" : "\(String(format: "%.3f", launchField.r))", "green" : "\(String(format: "%.3f", launchField.g))", "blue" : "\(String(format: "%.3f", launchField.b))" } }, "idiom" : "universal" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""", "PipApp/Assets.xcassets/LaunchBackground.colorset/Contents.json")
