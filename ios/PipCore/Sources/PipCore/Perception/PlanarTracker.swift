import Accelerate
import CoreGraphics
import simd

/// A grey image as Float32, row-major.
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: Float = 0) {
        self.init(width: width, height: height, pixels: [Float](repeating: fill, count: width * height))
    }

    /// From 8-bit luminance (a camera's Y plane), `rowBytes` apart.
    public init(luma: UnsafeRawPointer, width: Int, height: Int, rowBytes: Int) {
        var px = [Float](repeating: 0, count: width * height)
        px.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                let row = luma.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                vDSP_vfltu8(row, 1, out.baseAddress! + y * width, 1, vDSP_Length(width))
            }
        }
        self.init(width: width, height: height, pixels: px)
    }

    /// From a CGImage, as luminance 0–255.
    public init?(_ image: CGImage) {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        self.init(width: w, height: h, pixels: bytes.map(Float.init))
    }

    /// Half the size, smoothed first (a 5-tap binomial filter each way).
    public func halved() -> GrayImage {
        let kernel: [Float] = [1, 4, 6, 4, 1].map { $0 / 16 }
        var smooth = [Float](repeating: 0, count: pixels.count)
        var src = pixels
        src.withUnsafeMutableBufferPointer { s in
            smooth.withUnsafeMutableBufferPointer { d in
                var a = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var b = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                vImageSepConvolve_PlanarF(&a, &b, nil, 0, 0, kernel, 5, kernel, 5, 0, Pixel_F(0), vImage_Flags(kvImageEdgeExtend))
            }
        }
        let w2 = width / 2, h2 = height / 2
        var out = [Float](repeating: 0, count: w2 * h2)
        for y in 0..<h2 {
            for x in 0..<w2 { out[y * w2 + x] = smooth[(2 * y) * width + 2 * x] }
        }
        return GrayImage(width: w2, height: h2, pixels: out)
    }

    /// Resampled to another size (bilinear; a snapshot to the tracking size).
    public func resized(width w: Int, height h: Int) -> GrayImage {
        var out = [Float](repeating: 0, count: w * h)
        let sx = Float(width) / Float(w), sy = Float(height) / Float(h)
        pixels.withUnsafeBufferPointer { p in
            for y in 0..<h {
                for x in 0..<w { out[y * w + x] = sample((Float(x) + 0.5) * sx - 0.5, (Float(y) + 0.5) * sy - 0.5, p) }
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }

    /// Bilinear sample; positions outside are clamped to the edge.
    @inline(__always) func sample(_ x: Float, _ y: Float, _ p: UnsafeBufferPointer<Float>) -> Float {
        let xc = min(max(x, 0), Float(width - 1) - 0.001), yc = min(max(y, 0), Float(height - 1) - 0.001)
        let x0 = Int(xc), y0 = Int(yc)
        let fx = xc - Float(x0), fy = yc - Float(y0)
        let i = y0 * width + x0
        let a = p[i], b = p[i + 1], c = p[i + width], d = p[i + width + 1]
        return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy
    }
}

/// A homography as a 3×3 matrix (columns, simd): x' ~ H · (x, y, 1).
public extension simd_float3x3 {
    func apply(_ p: CGPoint) -> CGPoint {
        let v = self * simd_float3(Float(p.x), Float(p.y), 1)
        return CGPoint(x: CGFloat(v.x / v.z), y: CGFloat(v.y / v.z))
    }
}

/// Follows a flat (or nearly flat) object in the camera image, every frame: corners on the object
/// are followed with pyramidal Lucas–Kanade from frame to frame, checked by tracking them back,
/// and a homography from the object's first view to now is fitted to them with RANSAC. What sits
/// on the object (a key on a keyboard, a button on a remote) is mapped with that homography: it
/// stays on its place on the object whatever the object or the camera does, without depth and
/// without lag, and never jumps to a look-alike (it is never searched for, only followed).
public struct PlanarTracker: Sendable {
    public struct Settings: Sendable {
        /// Pyramid levels (each half the size of the one before).
        public var levels = 4
        /// Half the side of the Lucas–Kanade window.
        public var halfWindow = 5
        public var iterations = 12
        /// Points followed at once; new ones are found when fewer are left.
        public var points = 150
        public var minPoints = 60
        /// Corners at least this far apart (pixels at the tracking resolution).
        public var spacing: Float = 6
        /// Tracked forward and back, a point must come back within this many pixels.
        public var roundTrip: Float = 1.2
        /// RANSAC: a point within this many pixels of the fit counts.
        public var inlierDistance: Float = 1.5
        /// Fewer inliers than this, or this share of the points, and the object is lost.
        public var minInliers = 12
        public var minInlierShare: Float = 0.2
        /// A point that cannot be followed in a frame (motion blur at the start of a move) is kept
        /// where the fit puts it for this many frames before it is dropped.
        public var graceFrames = 3
        public init() {}
    }

    public enum State: Equatable, Sendable { case tracking, lost }

    public private(set) var settings: Settings
    public private(set) var state: State = .lost
    /// The object's first view (reference coordinates) → the current frame.
    public private(set) var homography = matrix_identity_float3x3
    /// Points that agreed with the last fit, and how far they were from it on average (pixels).
    public private(set) var inliers = 0
    public private(set) var residual: Float = 0

    /// Followed points: where they are now, and where they were on the object's first view.
    private var current: [SIMD2<Float>] = []
    private var reference: [SIMD2<Float>] = []
    /// Frames in a row each point could not be followed.
    private var misses: [Int] = []
    private var previous: [GrayImage] = []
    /// The first view (finest level): each frame's points are aligned against it too, so what
    /// motion blur shifted while they were followed from frame to frame does not stay.
    private var first: GrayImage?
    /// The object's outline on its first view (reference coordinates), where new corners may come from.
    private var outline: [SIMD2<Float>] = []

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Starts on `image` with the object inside `outline` (its mask's outer ring, image pixels).
    /// The image is the reference: homographies map from its coordinates.
    @discardableResult
    public mutating func start(image: GrayImage, outline ring: [CGPoint]) -> Bool {
        outline = ring.map { SIMD2(Float($0.x), Float($0.y)) }
        previous = Self.pyramid(image, levels: settings.levels)
        first = image
        homography = matrix_identity_float3x3
        current = Self.corners(in: image, inside: outline, count: settings.points, spacing: settings.spacing, avoiding: [])
        reference = current
        misses = Array(repeating: 0, count: current.count)
        inliers = current.count
        residual = 0
        state = current.count >= settings.minInliers ? .tracking : .lost
        return state == .tracking
    }

    /// The next frame. Returns the state; `homography` maps the reference to this frame.
    @discardableResult
    public mutating func track(_ image: GrayImage) -> State {
        guard state == .tracking, !previous.isEmpty else { return .lost }
        let next = Self.pyramid(image, levels: settings.levels)
        // Forward, then back: a point that does not return to where it was is not trusted.
        let forward = Self.lucasKanade(from: previous, to: next, points: current, settings: settings)
        let back = Self.lucasKanade(from: next, to: previous, points: forward.map { $0 ?? SIMD2(-1, -1) }, settings: settings)
        var followed: [Int] = []
        var measured = [SIMD2<Float>?](repeating: nil, count: current.count)
        for i in current.indices {
            guard let f = forward[i], let b = back[i], simd_distance(b, current[i]) <= settings.roundTrip else { continue }
            measured[i] = f
            followed.append(i)
        }
        previous = next
        guard followed.count >= settings.minInliers,
              let fit = Self.ransacHomography(from: followed.map { reference[$0] }, to: followed.map { measured[$0]! }, threshold: settings.inlierDistance) else {
            state = .lost
            return state
        }
        let share = Float(fit.inliers.count) / Float(max(current.count, 1))
        guard fit.inliers.count >= settings.minInliers, share >= settings.minInlierShare else {
            state = .lost
            return state
        }
        homography = fit.h
        inliers = fit.inliers.count
        residual = fit.residual
        // Each agreeing point aligned against the first view, seen through this fit: where it
        // really is now, whatever it drifted while followed from frame to frame. Then the fit again.
        if let first {
            let idx = fit.inliers.map { followed[$0] }
            let refined = Self.alignToFirst(first, next[0], h: homography, refs: idx.map { reference[$0] }, at: idx.map { measured[$0]! }, settings: settings)
            for (k, i) in idx.enumerated() { if let r = refined[k] { measured[i] = r } }
            if let refit = Self.ransacHomography(from: idx.map { reference[$0] }, to: idx.map { measured[$0]! }, threshold: settings.inlierDistance),
               refit.inliers.count >= settings.minInliers {
                homography = refit.h
                residual = refit.residual
            }
        }
        // Points that agree go on from where they were measured. One not followed this frame
        // (blur) goes on from where the fit puts it, for a few frames; one followed elsewhere
        // than the fit (a look-alike, the hand) is dropped.
        let agreeing = Set(fit.inliers.map { followed[$0] })
        var cur: [SIMD2<Float>] = [], ref: [SIMD2<Float>] = [], miss: [Int] = []
        for i in current.indices {
            if agreeing.contains(i), let m = measured[i] {
                cur.append(m); ref.append(reference[i]); miss.append(0)
            } else if measured[i] == nil, misses[i] + 1 <= settings.graceFrames {
                let q = homography * simd_float3(reference[i].x, reference[i].y, 1)
                cur.append(SIMD2(q.x / q.z, q.y / q.z)); ref.append(reference[i]); miss.append(misses[i] + 1)
            }
        }
        current = cur
        reference = ref
        misses = miss
        // New corners on the object when too few are followed.
        if current.count < settings.minPoints {
            let shown = outline.map { p -> SIMD2<Float> in let q = homography * simd_float3(p.x, p.y, 1); return SIMD2(q.x / q.z, q.y / q.z) }
            let fresh = Self.corners(in: image, inside: shown, count: settings.points - current.count, spacing: settings.spacing, avoiding: current)
            let inverse = homography.inverse
            for p in fresh {
                let q = inverse * simd_float3(p.x, p.y, 1)
                current.append(p)
                reference.append(SIMD2(q.x / q.z, q.y / q.z))
                misses.append(0)
            }
        }
        state = .tracking
        return state
    }

    /// Takes the object up again on `image`, from where `predicted` (reference → this image) says it
    /// is: from the moment it was outlined (the outline is of an earlier frame) or after it was
    /// lost. Each reference point is aligned against the first view, coarse to fine (a prediction
    /// may be some ten pixels off), and a homography is fitted to those that settle.
    @discardableResult
    public mutating func relocate(to image: GrayImage, predicted: simd_float3x3) -> State {
        guard let first, !reference.isEmpty || !outline.isEmpty else { return .lost }
        if reference.isEmpty {
            reference = Self.corners(in: first, inside: outline, count: settings.points, spacing: settings.spacing, avoiding: [])
        }
        let target = Self.pyramid(image, levels: settings.levels)
        let firstPyramid = Self.pyramid(first, levels: settings.levels)
        var points = reference.map { r -> SIMD2<Float> in let q = predicted * simd_float3(r.x, r.y, 1); return SIMD2(q.x / q.z, q.y / q.z) }
        var h = predicted
        var settled = [Bool](repeating: false, count: points.count)
        for level in stride(from: min(2, target.count - 1), through: 0, by: -1) {
            let s = Float(1 << level)
            let down = simd_float3x3(diagonal: SIMD3(1 / s, 1 / s, 1)), up = simd_float3x3(diagonal: SIMD3(s, s, 1))
            let hl = down * h * up
            let aligned = Self.alignToFirst(firstPyramid[level], target[level], h: hl, refs: reference.map { $0 / s }, at: points.map { $0 / s }, settings: settings)
            for i in points.indices {
                if let a = aligned[i] { points[i] = a * s; settled[i] = true } else { settled[i] = false }
            }
            let idx = points.indices.filter { settled[$0] }
            if idx.count >= settings.minInliers, let fit = Self.ransacHomography(from: idx.map { reference[$0] }, to: idx.map { points[$0] }, threshold: settings.inlierDistance * s) {
                h = fit.h
                // The rest go where the fit puts them, for the next level.
                for i in points.indices where !settled[i] {
                    let q = h * simd_float3(reference[i].x, reference[i].y, 1)
                    points[i] = SIMD2(q.x / q.z, q.y / q.z)
                }
            }
        }
        let idx = points.indices.filter { settled[$0] }
        guard idx.count >= settings.minInliers, let fit = Self.ransacHomography(from: idx.map { reference[$0] }, to: idx.map { points[$0] }, threshold: settings.inlierDistance),
              fit.inliers.count >= settings.minInliers, Float(fit.inliers.count) / Float(reference.count) >= settings.minInlierShare else {
            state = .lost
            return state
        }
        homography = fit.h
        inliers = fit.inliers.count
        residual = fit.residual
        let keep = fit.inliers.map { idx[$0] }
        current = keep.map { points[$0] }
        reference = keep.map { reference[$0] }
        misses = Array(repeating: 0, count: current.count)
        previous = target
        state = .tracking
        return state
    }

    /// Where a point of the reference view is now.
    public func map(_ p: CGPoint) -> CGPoint { homography.apply(p) }

    /// The homography mapping four or more points onto others (least squares).
    public static func homography(from a: [CGPoint], to b: [CGPoint]) -> simd_float3x3? {
        dlt(a.map { SIMD2(Float($0.x), Float($0.y)) }, b.map { SIMD2(Float($0.x), Float($0.y)) })
    }

    /// A polygon clipped to a rectangle (Sutherland–Hodgman): the part of an object's outline in a region.
    public static func clip(_ polygon: [CGPoint], to rect: CGRect) -> [CGPoint] {
        var out = polygon
        let edges: [(inside: (CGPoint) -> Bool, cross: (CGPoint, CGPoint) -> CGPoint)] = [
            ({ $0.x >= rect.minX }, { a, b in CGPoint(x: rect.minX, y: a.y + (b.y - a.y) * (rect.minX - a.x) / (b.x - a.x)) }),
            ({ $0.x <= rect.maxX }, { a, b in CGPoint(x: rect.maxX, y: a.y + (b.y - a.y) * (rect.maxX - a.x) / (b.x - a.x)) }),
            ({ $0.y >= rect.minY }, { a, b in CGPoint(x: a.x + (b.x - a.x) * (rect.minY - a.y) / (b.y - a.y), y: rect.minY) }),
            ({ $0.y <= rect.maxY }, { a, b in CGPoint(x: a.x + (b.x - a.x) * (rect.maxY - a.y) / (b.y - a.y), y: rect.maxY) }),
        ]
        for edge in edges {
            guard !out.isEmpty else { break }
            let input = out
            out = []
            for (i, cur) in input.enumerated() {
                let prev = input[(i + input.count - 1) % input.count]
                let ci = edge.inside(cur), pi = edge.inside(prev)
                if ci {
                    if !pi { out.append(edge.cross(prev, cur)) }
                    out.append(cur)
                } else if pi {
                    out.append(edge.cross(prev, cur))
                }
            }
        }
        return out
    }

    // MARK: Pyramid and corners

    static func pyramid(_ image: GrayImage, levels: Int) -> [GrayImage] {
        var out = [image]
        while out.count < levels, let last = out.last, last.width >= 40, last.height >= 40 { out.append(last.halved()) }
        return out
    }

    /// Shi–Tomasi corners inside a polygon: the smaller eigenvalue of the gradients' structure
    /// tensor over a 7×7 window, strongest first, at least `spacing` apart.
    static func corners(in image: GrayImage, inside polygon: [SIMD2<Float>], count: Int, spacing: Float, avoiding: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard count > 0, polygon.count >= 3 else { return [] }
        let w = image.width, h = image.height
        var lo = SIMD2<Float>(Float(w), Float(h)), hi = SIMD2<Float>(0, 0)
        for p in polygon { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let x0 = max(4, Int(lo.x)), y0 = max(4, Int(lo.y)), x1 = min(w - 5, Int(hi.x)), y1 = min(h - 5, Int(hi.y))
        guard x1 > x0 + 4, y1 > y0 + 4 else { return [] }
        let bw = x1 - x0 + 1, bh = y1 - y0 + 1
        var ixx = [Float](repeating: 0, count: bw * bh), iyy = ixx, ixy = ixx
        image.pixels.withUnsafeBufferPointer { p in
            for y in y0...y1 {
                for x in x0...x1 {
                    let gx = (p[y * w + x + 1] - p[y * w + x - 1]) * 0.5
                    let gy = (p[(y + 1) * w + x] - p[(y - 1) * w + x]) * 0.5
                    let i = (y - y0) * bw + (x - x0)
                    ixx[i] = gx * gx; iyy[i] = gy * gy; ixy[i] = gx * gy
                }
            }
        }
        // Sums over 7×7 windows.
        func boxed(_ a: [Float]) -> [Float] {
            var src = a, out = [Float](repeating: 0, count: a.count)
            let ones = [Float](repeating: 1, count: 7)
            src.withUnsafeMutableBufferPointer { s in
                out.withUnsafeMutableBufferPointer { o in
                    var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(bh), width: vImagePixelCount(bw), rowBytes: bw * 4)
                    var ob = vImage_Buffer(data: o.baseAddress, height: vImagePixelCount(bh), width: vImagePixelCount(bw), rowBytes: bw * 4)
                    vImageSepConvolve_PlanarF(&sb, &ob, nil, 0, 0, ones, 7, ones, 7, 0, Pixel_F(0), vImage_Flags(kvImageEdgeExtend))
                }
            }
            return out
        }
        let sxx = boxed(ixx), syy = boxed(iyy), sxy = boxed(ixy)
        var candidates: [(score: Float, p: SIMD2<Float>)] = []
        var best: Float = 0
        for y in stride(from: 3, to: bh - 3, by: 1) {
            for x in stride(from: 3, to: bw - 3, by: 1) {
                let i = y * bw + x
                let a = sxx[i], c = syy[i], b = sxy[i]
                let lambda = (a + c) / 2 - sqrt(((a - c) / 2) * ((a - c) / 2) + b * b)
                guard lambda > 0 else { continue }
                // A local maximum in its 3×3 neighbourhood.
                var isMax = true
                for dy in -1...1 where isMax {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let j = (y + dy) * bw + x + dx
                        let aj = sxx[j], cj = syy[j], bj = sxy[j]
                        if (aj + cj) / 2 - sqrt(((aj - cj) / 2) * ((aj - cj) / 2) + bj * bj) > lambda { isMax = false; break }
                    }
                }
                guard isMax else { continue }
                let p = SIMD2<Float>(Float(x + x0), Float(y + y0))
                guard Self.inside(p, polygon) else { continue }
                candidates.append((lambda, p))
                best = max(best, lambda)
            }
        }
        candidates.sort { $0.score > $1.score }
        var chosen: [SIMD2<Float>] = []
        let minScore = best * 0.01
        let spacing2 = spacing * spacing
        for c in candidates where c.score >= minScore {
            if chosen.contains(where: { simd_distance_squared($0, c.p) < spacing2 }) || avoiding.contains(where: { simd_distance_squared($0, c.p) < spacing2 }) { continue }
            chosen.append(c.p)
            if chosen.count >= count { break }
        }
        return chosen
    }

    static func inside(_ p: SIMD2<Float>, _ polygon: [SIMD2<Float>]) -> Bool {
        var c = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
            j = i
        }
        return c
    }

    // MARK: Lucas–Kanade

    /// Pyramidal Lucas–Kanade (Bouguet): each point's displacement from coarse to fine, nil when it
    /// cannot be followed (no texture to follow, or it left the image).
    static func lucasKanade(from a: [GrayImage], to b: [GrayImage], points: [SIMD2<Float>], settings: Settings) -> [SIMD2<Float>?] {
        let levels = min(a.count, b.count)
        let hw = settings.halfWindow
        var out = [SIMD2<Float>?](repeating: nil, count: points.count)
        for (k, p0) in points.enumerated() {
            guard p0.x >= 0, p0.y >= 0, p0.x < Float(a[0].width), p0.y < Float(a[0].height) else { continue }
            var guess = SIMD2<Float>(0, 0)
            var ok = true
            for level in stride(from: levels - 1, through: 0, by: -1) {
                let scale = Float(1 << level)
                let p = p0 / scale
                let ia = a[level], ib = b[level]
                var d = SIMD2<Float>(0, 0)
                let converged: Bool = ia.pixels.withUnsafeBufferPointer { pa in
                    ib.pixels.withUnsafeBufferPointer { pb in
                        // The window's gradients and values in the first image (fixed).
                        var gxx: Float = 0, gyy: Float = 0, gxy: Float = 0
                        let n = (2 * hw + 1) * (2 * hw + 1)
                        var tx = [Float](repeating: 0, count: n), ty = tx, tv = tx
                        var i = 0
                        for dy in -hw...hw {
                            for dx in -hw...hw {
                                let x = p.x + Float(dx), y = p.y + Float(dy)
                                let gx = (ia.sample(x + 1, y, pa) - ia.sample(x - 1, y, pa)) * 0.5
                                let gy = (ia.sample(x, y + 1, pa) - ia.sample(x, y - 1, pa)) * 0.5
                                tx[i] = gx; ty[i] = gy; tv[i] = ia.sample(x, y, pa)
                                gxx += gx * gx; gyy += gy * gy; gxy += gx * gy
                                i += 1
                            }
                        }
                        let det = gxx * gyy - gxy * gxy
                        let minEig = (gxx + gyy) / 2 - sqrt(((gxx - gyy) / 2) * ((gxx - gyy) / 2) + gxy * gxy)
                        guard det > 1e-6, minEig / Float(n) > 1e-3 else { return false }
                        for _ in 0..<settings.iterations {
                            var bx: Float = 0, by: Float = 0
                            var j = 0
                            for dy in -hw...hw {
                                for dx in -hw...hw {
                                    let x = p.x + Float(dx) + guess.x + d.x, y = p.y + Float(dy) + guess.y + d.y
                                    let diff = tv[j] - ib.sample(x, y, pb)
                                    bx += diff * tx[j]; by += diff * ty[j]
                                    j += 1
                                }
                            }
                            let step = SIMD2<Float>((gyy * bx - gxy * by) / det, (gxx * by - gxy * bx) / det)
                            d += step
                            if simd_length(step) < 0.01 { break }
                        }
                        return true
                    }
                }
                guard converged else { ok = false; break }
                guess = level > 0 ? 2 * (guess + d) : guess + d
            }
            let q = p0 + guess
            guard ok, q.x >= 0, q.y >= 0, q.x < Float(a[0].width), q.y < Float(a[0].height) else { continue }
            out[k] = q
        }
        return out
    }

    // MARK: Alignment against the first view

    /// Each point's window in `current`, compared with the first view seen through `h` (the first
    /// view sampled where `h` maps each window pixel from): the shift that makes them agree, by
    /// Lucas–Kanade with the brightness levelled; nil where the window has no texture, the
    /// alignment does not settle, or it would move the point more than a few pixels.
    static func alignToFirst(_ first: GrayImage, _ current: GrayImage, h: simd_float3x3, refs: [SIMD2<Float>], at points: [SIMD2<Float>], settings: Settings) -> [SIMD2<Float>?] {
        let hw = settings.halfWindow, side = 2 * hw + 1, n = side * side
        let inverse = h.inverse
        return first.pixels.withUnsafeBufferPointer { pf in
            current.pixels.withUnsafeBufferPointer { pc in
                points.map { c -> SIMD2<Float>? in
                    // The template on a (side+2)² grid, for its gradients by central differences.
                    let g = side + 2
                    var t = [Float](repeating: 0, count: g * g)
                    for gy in 0..<g {
                        for gx in 0..<g {
                            let x = c.x + Float(gx - hw - 1), y = c.y + Float(gy - hw - 1)
                            let q = inverse * simd_float3(x, y, 1)
                            t[gy * g + gx] = first.sample(q.x / q.z, q.y / q.z, pf)
                        }
                    }
                    var tv = [Float](repeating: 0, count: n), tx = tv, ty = tv
                    var gxx: Float = 0, gyy: Float = 0, gxy: Float = 0, mean: Float = 0
                    for y in 0..<side {
                        for x in 0..<side {
                            let i = y * side + x, j = (y + 1) * g + x + 1
                            tv[i] = t[j]
                            tx[i] = (t[j + 1] - t[j - 1]) * 0.5
                            ty[i] = (t[j + g] - t[j - g]) * 0.5
                            gxx += tx[i] * tx[i]; gyy += ty[i] * ty[i]; gxy += tx[i] * ty[i]
                            mean += tv[i]
                        }
                    }
                    mean /= Float(n)
                    let det = gxx * gyy - gxy * gxy
                    let minEig = (gxx + gyy) / 2 - sqrt(((gxx - gyy) / 2) * ((gxx - gyy) / 2) + gxy * gxy)
                    guard det > 1e-6, minEig / Float(n) > 1e-2 else { return nil }
                    var d = SIMD2<Float>(0, 0)
                    var settled = false
                    for _ in 0..<settings.iterations {
                        var samples = [Float](repeating: 0, count: n)
                        var m: Float = 0
                        var i = 0
                        for dy in -hw...hw {
                            for dx in -hw...hw {
                                samples[i] = current.sample(c.x + Float(dx) + d.x, c.y + Float(dy) + d.y, pc)
                                m += samples[i]
                                i += 1
                            }
                        }
                        m /= Float(n)
                        var bx: Float = 0, by: Float = 0
                        for k in 0..<n {
                            let diff = (tv[k] - mean) - (samples[k] - m)
                            bx += diff * tx[k]; by += diff * ty[k]
                        }
                        let step = SIMD2<Float>((gyy * bx - gxy * by) / det, (gxx * by - gxy * bx) / det)
                        d += step
                        if simd_length(step) < 0.01 { settled = true; break }
                    }
                    guard settled, simd_length(d) < 3 else { return nil }
                    return c + d
                }
            }
        }
    }

    // MARK: Homography

    /// The homography mapping `from` to `to` that most points agree with (RANSAC on four points,
    /// then a least-squares fit to all that agree).
    static func ransacHomography(from: [SIMD2<Float>], to: [SIMD2<Float>], threshold: Float, iterations: Int = 300) -> (h: simd_float3x3, inliers: [Int], residual: Float)? {
        let n = from.count
        guard n >= 4 else { return nil }
        var rng = SplitMix64(seed: UInt64(n) &* 0x9E37_79B9_7F4A_7C15)
        var bestInliers: [Int] = []
        let t2 = threshold * threshold
        for _ in 0..<iterations {
            var pick = Set<Int>()
            while pick.count < 4 { pick.insert(Int(rng.next() % UInt64(n))) }
            let idx = Array(pick)
            guard let h = Self.dlt(idx.map { from[$0] }, idx.map { to[$0] }) else { continue }
            var inl: [Int] = []
            for i in 0..<n where Self.error2(h, from[i], to[i]) < t2 { inl.append(i) }
            if inl.count > bestInliers.count {
                bestInliers = inl
                if inl.count > n * 9 / 10 { break }
            }
        }
        guard bestInliers.count >= 4 else { return nil }
        // Refit to all inliers, and take the inliers of that fit.
        guard var h = Self.dlt(bestInliers.map { from[$0] }, bestInliers.map { to[$0] }) else { return nil }
        var inl = (0..<n).filter { Self.error2(h, from[$0], to[$0]) < t2 }
        if inl.count >= 4, let refit = Self.dlt(inl.map { from[$0] }, inl.map { to[$0] }) {
            h = refit
            inl = (0..<n).filter { Self.error2(h, from[$0], to[$0]) < t2 }
        }
        let residual = inl.isEmpty ? 0 : inl.map { sqrt(Self.error2(h, from[$0], to[$0])) }.reduce(0, +) / Float(inl.count)
        return (h, inl, residual)
    }

    @inline(__always) static func error2(_ h: simd_float3x3, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let v = h * simd_float3(a.x, a.y, 1)
        guard abs(v.z) > 1e-9 else { return .infinity }
        let d = SIMD2(v.x / v.z, v.y / v.z) - b
        return simd_length_squared(d)
    }

    /// Normalised direct linear transform: the least-squares homography for ≥ 4 correspondences.
    static func dlt(_ a: [SIMD2<Float>], _ b: [SIMD2<Float>]) -> simd_float3x3? {
        let n = a.count
        guard n >= 4 else { return nil }
        func normaliser(_ pts: [SIMD2<Float>]) -> simd_double3x3 {
            let c = pts.reduce(SIMD2<Double>(0, 0)) { $0 + SIMD2(Double($1.x), Double($1.y)) } / Double(pts.count)
            let mean = pts.map { simd_distance(SIMD2(Double($0.x), Double($0.y)), c) }.reduce(0, +) / Double(pts.count)
            let s = mean > 1e-9 ? sqrt(2) / mean : 1
            return simd_double3x3(rows: [SIMD3(s, 0, -s * c.x), SIMD3(0, s, -s * c.y), SIMD3(0, 0, 1)])
        }
        let ta = normaliser(a), tb = normaliser(b)
        // A^T A (9×9) of the 2n×9 system, then its eigenvector of the smallest eigenvalue.
        var ata = [Double](repeating: 0, count: 81)
        for i in 0..<n {
            let p = ta * SIMD3(Double(a[i].x), Double(a[i].y), 1), q = tb * SIMD3(Double(b[i].x), Double(b[i].y), 1)
            let x = p.x / p.z, y = p.y / p.z, u = q.x / q.z, v = q.y / q.z
            let r1: [Double] = [-x, -y, -1, 0, 0, 0, u * x, u * y, u]
            let r2: [Double] = [0, 0, 0, -x, -y, -1, v * x, v * y, v]
            for r in 0..<9 {
                for c in 0..<9 { ata[r * 9 + c] += r1[r] * r1[c] + r2[r] * r2[c] }
            }
        }
        guard let h = smallestEigenvector(ata, size: 9) else { return nil }
        let hn = simd_double3x3(rows: [SIMD3(h[0], h[1], h[2]), SIMD3(h[3], h[4], h[5]), SIMD3(h[6], h[7], h[8])])
        let full = tb.inverse * hn * ta
        guard abs(full[2][2]) > 1e-12 else { return nil }
        let m = full * (1 / full[2][2])
        return simd_float3x3(columns: (SIMD3(Float(m[0][0]), Float(m[0][1]), Float(m[0][2])),
                                       SIMD3(Float(m[1][0]), Float(m[1][1]), Float(m[1][2])),
                                       SIMD3(Float(m[2][0]), Float(m[2][1]), Float(m[2][2]))))
    }

    /// The eigenvector of a symmetric matrix's smallest eigenvalue (cyclic Jacobi rotations).
    static func smallestEigenvector(_ m: [Double], size n: Int) -> [Double]? {
        var a = m
        var v = [Double](repeating: 0, count: n * n)
        for i in 0..<n { v[i * n + i] = 1 }
        for _ in 0..<50 {
            var off = 0.0
            for p in 0..<n { for q in (p + 1)..<n { off += a[p * n + q] * a[p * n + q] } }
            if off < 1e-22 { break }
            for p in 0..<n {
                for q in (p + 1)..<n where abs(a[p * n + q]) > 1e-300 {
                    let theta = (a[q * n + q] - a[p * n + p]) / (2 * a[p * n + q])
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + sqrt(theta * theta + 1))
                    let c = 1 / sqrt(t * t + 1), s = t * c
                    for k in 0..<n {
                        let akp = a[k * n + p], akq = a[k * n + q]
                        a[k * n + p] = c * akp - s * akq
                        a[k * n + q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p * n + k], aqk = a[q * n + k]
                        a[p * n + k] = c * apk - s * aqk
                        a[q * n + k] = s * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = v[k * n + p], vkq = v[k * n + q]
                        v[k * n + p] = c * vkp - s * vkq
                        v[k * n + q] = s * vkp + c * vkq
                    }
                }
            }
        }
        var best = 0
        for i in 1..<n where a[i * n + i] < a[best * n + best] { best = i }
        let out = (0..<n).map { v[$0 * n + best] }
        return out.allSatisfy(\.isFinite) ? out : nil
    }
}

/// A small deterministic random number generator (RANSAC samples).
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
