import PipCore
import UIKit
import simd

/// Draws the cues on the camera view. The model chose the meaning; this file chooses the visuals,
/// in the one visual language of CueArt: the action colour for what to do, red only for danger,
/// green only for verified, and a distinct shape for each kind of cue. Outlines draw themselves on
/// round their object when a cue appears.
final class OverlayView: UIView {
    static let danger = UIColor(red: 1, green: 0.27, blue: 0.23, alpha: 1)

    private let dangerBanner = UILabel()
    /// Labels: SF Rounded, semibold.
    private let chipFont: CTFont = {
        let base = UIFont.systemFont(ofSize: 14, weight: .semibold)
        let rounded = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 14) } ?? base
        return rounded as CTFont
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        dangerBanner.textColor = .white
        dangerBanner.backgroundColor = Self.danger.withAlphaComponent(0.92)
        dangerBanner.font = .systemFont(ofSize: 16, weight: .semibold)
        dangerBanner.textAlignment = .center
        dangerBanner.numberOfLines = 2
        dangerBanner.layer.cornerRadius = 14
        dangerBanner.layer.masksToBounds = true
        dangerBanner.isHidden = true
        addSubview(dangerBanner)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Marks whose object moved in the image: drawn where the object is now (see ImageFollower).
    var adjust: [Int: ImageFollower.Adjust] = [:]

    /// `project`: a world point on screen, nil behind the camera. `direction`: the way to turn
    /// towards a world point on screen (x right, y down), also when it is behind the camera.
    func render(_ annotations: [AnnotationBoard.Annotation], now: TimeInterval, marks: [Int: AnchoredMark],
                project base: @escaping (simd_float3) -> CGPoint?, direction: @escaping (simd_float3) -> CGVector?) {
        // Each mark's projection: from its room anchor, moved on screen when its object moved.
        let adjust = self.adjust
        func proj(_ mark: AnchoredMark?) -> (simd_float3) -> CGPoint? {
            guard let mark, let a = adjust[mark.id] else { return base }
            if a.hidden { return { _ in nil } }
            return { w in base(w).map { CGPoint(x: a.to.x + ($0.x - a.from.x) * a.scale, y: a.to.y + ($0.y - a.from.y) * a.scale) } }
        }
        // Where an edge hint points for a mark: its place on screen or, behind the camera, far off
        // in its direction. Nothing for an outline hidden because its object moved.
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        func aim(_ mark: AnchoredMark?) -> CGPoint? {
            guard let mark else { return nil }
            if let p = proj(mark)(mark.centroid) { return p }
            guard adjust[mark.id] == nil, let d = direction(mark.centroid) else { return nil }
            let len = max(hypot(d.dx, d.dy), 1e-6)
            return CGPoint(x: centre.x + d.dx / len * 10_000, y: centre.y + d.dy / len * 10_000)
        }
        func polygons(_ m: Int) -> [[CGPoint]]? { screenPolygons(marks[m], proj(marks[m])) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayers?.filter { $0 !== dangerBanner.layer }.forEach { $0.removeFromSuperlayer() }
        var generalDanger: String?
        let dangerShown = annotations.contains { if case .danger = $0.cue { return true } else { return false } }
        // Labels keep clear of the status line at the top, and of the danger banner.
        let topInset = safeAreaInsets.top + (dangerShown ? 116 : 56)
        let scale = traitCollection.displayScale
        func mark(_ rings: [[CGPoint]], _ palette: CueArt.Palette, _ a: AnnotationBoard.Annotation, fill: CGFloat = 0.08, width: CGFloat = 2,
                  dash: [CGFloat]? = nil, opacity: CGFloat, emphasis: Bool = true, label: String? = nil, filledLabel: Bool = false) {
            add(CueArt.mark(rings, palette: palette, progress: CueArt.progress(since: a.shownAt, now: now),
                            pop: emphasis ? CueArt.pop(since: a.shownAt, now: now) : 0, fill: fill, width: width, dash: dash,
                            opacity: opacity, label: label, filledLabel: filledLabel, font: chipFont, scale: scale, view: bounds, topInset: topInset))
        }

        var hinted = Set<Int>()
        for a in annotations {
            let alpha = opacity(a, now: now)
            // Off screen: a button at the edge points the way back, for every kind of cue.
            if let first = a.cue.marks.first, let target = marks[first], !a.cue.marks.contains(where: { polygons($0) != nil }) {
                if case .danger(_, let reason) = a.cue { generalDanger = reason }
                if hinted.insert(first).inserted {
                    edgeHint(aim(target), palette: { if case .danger = a.cue { return CueArt.danger } else { return CueArt.action } }(), force: true)
                }
                continue
            }
            switch a.cue {
            case .outline(let m):
                if let p = polygons(m) { mark(p, CueArt.action, a, opacity: alpha) } else { edgeHint(aim(marks[m]), palette: CueArt.action) }
            case .candidates(let ms):
                // Look-alikes: dotted, numbered, no emphasis on any of them.
                for (i, m) in ms.enumerated() {
                    guard let p = polygons(m) else { continue }
                    mark(p, CueArt.neutral, a, fill: 0, dash: CueArt.dots, opacity: alpha, emphasis: false, label: "\(i + 1)")
                }
            case .ring(let m, let label):
                // A small target: its contour, tinted, a reticle round it when it is small on
                // screen, and its step number above it.
                guard let p = polygons(m) else { edgeHint(aim(marks[m]), palette: CueArt.action); continue }
                mark(p, CueArt.action, a, fill: 0.14, opacity: alpha, label: label)
            case .move(let m, let dir):
                guard let target = marks[m] else { continue }
                let project = proj(target)
                if let p = polygons(m) { add(CueArt.outline(p, palette: CueArt.action, progress: CueArt.progress(since: a.shownAt, now: now), fill: 0, width: 1.5, opacity: alpha * 0.8)) }
                let t = CGFloat(now - a.shownAt)
                if dir == .in || dir == .out {
                    if let c = project(target.centroid) {
                        add(CueArt.pulse(centre: c, inward: dir == .in, palette: CueArt.action, phase: (t / 1.2).truncatingRemainder(dividingBy: 1), opacity: alpha))
                    }
                } else if let (s, e) = target.arrow(dir) {
                    if let a0 = project(s), let a1 = project(e) {
                        add(CueArt.arrow(from: a0, to: a1, palette: CueArt.action, phase: (t / 1.4).truncatingRemainder(dividingBy: 1), opacity: alpha))
                    }
                } else if let c = project(target.centroid) {
                    // No surface to lay it on: along the screen, about half the outline's size.
                    let size = polygons(m).map { b in max(Contour.bounds(b).width, Contour.bounds(b).height) } ?? 80
                    let len = max(60, size * 0.55), v = dir.screenVector
                    add(CueArt.arrow(from: c, to: CGPoint(x: c.x + v.dx * len, y: c.y + v.dy * len), palette: CueArt.action,
                                     phase: (t / 1.4).truncatingRemainder(dividingBy: 1), opacity: alpha))
                }
            case .rotate(let m, let dir, _):
                guard let target = marks[m], let c = proj(target)(target.centroid) else { continue }
                let r = max(26, (polygons(m).map { Contour.bounds($0).width } ?? 40) * 0.55)
                add(CueArt.rotation(centre: c, radius: r, clockwise: dir == .cw, palette: CueArt.action,
                                    progress: CueArt.progress(since: a.shownAt, now: now), opacity: alpha))
            case .place(let m):
                if let p = polygons(m) { mark(p, CueArt.action, a, fill: 0.06, dash: CueArt.dashes, opacity: alpha) }
            case .sequence(let ms):
                for (i, m) in ms.enumerated() {
                    guard let p = polygons(m) else { continue }
                    mark(p, CueArt.action, a, fill: i == 0 ? 0.08 : 0, width: i == 0 ? 2 : 1.5, opacity: alpha * (i == 0 ? 1 : 0.6),
                         emphasis: i == 0, label: "\(i + 1)")
                }
            case .danger(let m, let reason):
                if let m, let p = polygons(m) { mark(p, CueArt.danger, a, fill: 0.16, opacity: 1, label: "!", filledLabel: true) }
                generalDanger = reason
            case .landmark(let m, let name):
                guard let p = polygons(m) else { continue }
                mark(p, CueArt.action, a, fill: 0.1, opacity: alpha, label: name)
            case .offscreen(let m):
                edgeHint(aim(marks[m]), palette: CueArt.action, force: true)
            case .verified(let m):
                guard let target = marks[m] else { continue }
                if let p = polygons(m) {
                    mark(p, CueArt.verified, a, fill: 0.1, opacity: alpha, label: "✓", filledLabel: true)
                } else if let c = proj(target)(target.centroid) {
                    add(CueArt.chip("✓", centre: c, palette: CueArt.verified, font: chipFont, scale: scale, filled: true, opacity: alpha))
                }
            case .clear, .state, .locate, .needView, .remember, .task, .readPages, .find, .list, .lookup:
                break
            }
        }

        if let reason = generalDanger {
            dangerBanner.text = "⚠︎ \(reason)"
            dangerBanner.frame = CGRect(x: 16, y: safeAreaInsets.top + 56, width: bounds.width - 32, height: 52)
            dangerBanner.isHidden = false
        } else {
            dangerBanner.isHidden = true
        }
        CATransaction.commit()
    }

    private func add(_ layers: [CALayer]) {
        for l in layers { layer.addSublayer(l) }
    }

    // MARK: Lifetimes

    /// Fades in over 0.25 s; transient cues fade out over their last 0.6 s.
    private func opacity(_ a: AnnotationBoard.Annotation, now: TimeInterval) -> CGFloat {
        let fadeIn = min(1, (now - a.shownAt) / 0.25)
        if case .transient(let until) = a.lifetime {
            return CGFloat(fadeIn * min(1, max(0, (until - now) / 0.6)))
        }
        return CGFloat(fadeIn)
    }

    // MARK: Geometry

    private func screenPolygons(_ mark: AnchoredMark?, _ project: (simd_float3) -> CGPoint?) -> [[CGPoint]]? {
        guard let mark else { return nil }
        let polys = mark.polygons.compactMap { ring -> [CGPoint]? in
            let pts = ring.compactMap(project)
            return pts.count == ring.count ? pts : nil
        }
        guard !polys.isEmpty else { return nil }
        // Entirely off screen → let the caller draw an edge hint instead.
        return polys.contains(where: { $0.contains(where: { bounds.insetBy(dx: -20, dy: -20).contains($0) }) }) ? polys : nil
    }

    /// A round button at the screen edge pointing at a mark that is out of view (`p`, see `aim`),
    /// clear of the status line at the top and the controls at the bottom.
    private func edgeHint(_ p: CGPoint?, palette: CueArt.Palette, force: Bool = false) {
        guard let p else { return }
        let inner = CGRect(x: 30, y: safeAreaInsets.top + 80, width: bounds.width - 60,
                           height: bounds.height - safeAreaInsets.top - safeAreaInsets.bottom - 220)
        guard inner.width > 0, inner.height > 0 else { return }
        if inner.contains(p), !force { return }
        let c = CGPoint(x: inner.midX, y: inner.midY)
        let dx = p.x - c.x, dy = p.y - c.y
        guard abs(dx) + abs(dy) > 1 else { return }
        // Onto the border of `inner`, along the line from its centre towards the mark.
        let t = min(inner.width / 2 / max(abs(dx), 1e-6), inner.height / 2 / max(abs(dy), 1e-6))
        add(CueArt.edgeHint(at: CGPoint(x: c.x + dx * t, y: c.y + dy * t), angle: atan2(dy, dx), palette: palette))
    }
}
