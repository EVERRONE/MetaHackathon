import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws numbered marks on a frame (set-of-marks prompting), so Spark can choose between
/// SAM instances by number instead of drawing its own, less precise boxes.
public enum SetOfMarks {
    /// Thin outlines plus a number badge near the top of each instance.
    public static func render(_ image: CGImage, instances: [SegmentInstance]) -> CGImage? {
        let w = image.width
        let h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Work in image coordinates: origin top-left, y down.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        let scale = CGFloat(max(w, h)) / 1280
        let line = max(1.5, 2 * scale)
        let halo = CGColor(red: 0, green: 0, blue: 0, alpha: 0.75)
        let stroke = CGColor(red: 0.2, green: 1, blue: 1, alpha: 1)

        for inst in instances {
            for ring in inst.outlinePoints where ring.count >= 3 {
                let path = CGMutablePath()
                path.addLines(between: ring)
                path.closeSubpath()
                ctx.addPath(path)
                ctx.setStrokeColor(halo)
                ctx.setLineWidth(line + 2 * scale)
                ctx.strokePath()
                ctx.addPath(path)
                ctx.setStrokeColor(stroke)
                ctx.setLineWidth(line)
                ctx.strokePath()
            }
        }
        // Badges after all outlines, so no outline crosses a number.
        let fontSize = max(13, 17 * scale)
        for inst in instances {
            let box = inst.boxRect
            // A small outline keeps what is inside it visible: its number goes right above it (or
            // below when there is no room above). Above and to the left, a number sat nearer the
            // neighbour of a key in a tilted row (1 Nov: the power key's number was taken for delete's).
            let small = box.width < fontSize * 4 || box.height < fontSize * 4
            let anchor: CGPoint
            if small {
                let above = box.minY - fontSize * 0.8
                anchor = CGPoint(x: min(max(fontSize, box.midX), CGFloat(w) - fontSize), y: above > fontSize ? above : box.maxY + fontSize * 0.8)
            } else {
                anchor = CGPoint(x: box.midX, y: min(box.minY + fontSize * 0.9, box.midY))
            }
            drawBadge(String(inst.id), at: anchor, fontSize: fontSize, in: ctx)
        }
        return ctx.makeImage()
    }

    private static func drawBadge(_ text: String, at centre: CGPoint, fontSize: CGFloat, in ctx: CGContext) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 0.2, alpha: 1)]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetImageBounds(ctLine, ctx)
        let pad = fontSize * 0.3
        let rect = CGRect(x: centre.x - bounds.width / 2 - pad, y: centre.y - fontSize / 2 - pad * 0.6,
                          width: bounds.width + 2 * pad, height: fontSize + pad * 1.2)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.85))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: pad, cornerHeight: pad, transform: nil))
        ctx.fillPath()

        ctx.saveGState()
        // Text draws upright in a y-up space.
        ctx.translateBy(x: rect.minX + pad - bounds.minX, y: rect.maxY - pad * 0.6 - fontSize * 0.18)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(ctLine, ctx)
        ctx.restoreGState()
    }

    /// A region of the image, enlarged by `scale`.
    /// The image with a yellow cross (dark-rimmed) at `p` (pixels, top-left origin): where the guide
    /// pointed, for a verifier to see.
    public static func cross(_ image: CGImage, at p: CGPoint) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let q = CGPoint(x: p.x, y: CGFloat(h) - p.y)
        let arm = max(8, CGFloat(max(w, h)) * 0.025)
        for (color, width) in [(CGColor(red: 0, green: 0, blue: 0, alpha: 0.8), CGFloat(5)), (CGColor(red: 1, green: 0.9, blue: 0, alpha: 1), CGFloat(2.5))] {
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: q.x - arm, y: q.y)); ctx.addLine(to: CGPoint(x: q.x - arm * 0.35, y: q.y))
            ctx.move(to: CGPoint(x: q.x + arm * 0.35, y: q.y)); ctx.addLine(to: CGPoint(x: q.x + arm, y: q.y))
            ctx.move(to: CGPoint(x: q.x, y: q.y - arm)); ctx.addLine(to: CGPoint(x: q.x, y: q.y - arm * 0.35))
            ctx.move(to: CGPoint(x: q.x, y: q.y + arm * 0.35)); ctx.addLine(to: CGPoint(x: q.x, y: q.y + arm))
            ctx.strokePath()
        }
        return ctx.makeImage()
    }

    private static let sharpening = CIContext(options: [.useSoftwareRenderer: false])

    /// The image with a light unsharp mask. A camera frame in dim light is soft: on 1 Nov the model
    /// could not read the ⏻ on a backlit keyboard's power key and asked for another view (0 of 10);
    /// sharpened, it pointed at the key 3 times of 4, each time grounded on it.
    public static func sharpened(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIUnsharpMask") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(1.5, forKey: kCIInputRadiusKey)
        filter.setValue(0.8, forKey: kCIInputIntensityKey)
        guard let output = filter.outputImage else { return nil }
        return sharpening.createCGImage(output, from: input.extent)
    }

    public static func crop(_ image: CGImage, to rect: CGRect, scale: CGFloat) -> CGImage? {
        guard let region = image.cropping(to: rect) else { return nil }
        return draw(region, width: Int((rect.width * scale).rounded()), height: Int((rect.height * scale).rounded()))
    }

    /// The image scaled down so its long side is at most `maxSide`.
    public static func resize(_ image: CGImage, maxSide: Int) -> CGImage? {
        let long = max(image.width, image.height)
        guard long > maxSide else { return image }
        let s = CGFloat(maxSide) / CGFloat(long)
        return draw(image, width: Int((CGFloat(image.width) * s).rounded()), height: Int((CGFloat(image.height) * s).rounded()))
    }

    private static func draw(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    public static func jpeg(_ image: CGImage, quality: Double = 0.8) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Decodes an image file, applying its EXIF orientation, and scales the long side to `maxSide`.
    public static func load(_ data: Data, maxSide: Int = 1280) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
