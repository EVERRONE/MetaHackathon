import CoreGraphics
import simd

/// The face of the object a small target sits on, as a reference image for ARKit's image tracking,
/// and the target's outline laid onto that image in metres (see ImageLock in the app).
public enum ObjectFace {
    public struct Made {
        public var image: CGImage
        /// The image's width in the world, in metres (from LiDAR depth).
        public var physicalWidth: CGFloat
        /// The key's outline in the image's plane: x right, y out of the image, z down the image.
        public var local: [[simd_float3]]
    }

    /// `key`: the pointed-at instance, `object`: the object it is on (pixels of `image`),
    /// `focal`: focal length in those pixels, `distance`: metres from the camera to the key.
    public static func make(key: SegmentInstance, object: SegmentInstance?, image: CGImage, focal: CGFloat, distance: Float) -> Made? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let k = key.boxRect
        let side = max(k.width, k.height)
        // The object's face around the key (at most six keys each way); without a known object, a
        // tight patch of about a key and a half around it, which on a device is mostly the device.
        var region = object.map { $0.boxRect.intersection(k.insetBy(dx: -6 * side, dy: -6 * side)) } ?? k.insetBy(dx: -1.5 * side, dy: -1.5 * side)
        region = region.union(k.insetBy(dx: -1.5 * side, dy: -1.5 * side)).intersection(bounds).integral
        guard region.width >= 96, region.height >= 96, let crop = image.cropping(to: region) else { return nil }
        guard let face = object.map({ masked(crop, by: $0, region: region) }) ?? crop else { return nil }
        let width = region.width * CGFloat(distance) / max(focal, 100)
        let height = width * region.height / region.width
        let local = key.regularized().outlinePoints.map { ring in
            ring.map { p in
                simd_float3(Float(((p.x - region.minX) / region.width - 0.5) * width), 0.002,
                            Float(((p.y - region.minY) / region.height - 0.5) * height))
            }
        }
        return Made(image: face, physicalWidth: width, local: local)
    }

    /// The crop with everything outside the object's mask a flat grey, so the background (which
    /// does not move with the object) gives the tracker nothing to follow.
    public static func masked(_ crop: CGImage, by object: SegmentInstance, region: CGRect) -> CGImage? {
        let w = crop.width, h = crop.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // The outline is in top-left pixels; CoreGraphics' origin is bottom-left.
        let path = CGMutablePath()
        for ring in object.outlinePoints where ring.count >= 3 {
            path.addLines(between: ring.map { CGPoint(x: $0.x - region.minX, y: CGFloat(h) - ($0.y - region.minY)) })
            path.closeSubpath()
        }
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
