import PipCore
import UIKit
import simd

/// Draws the cues on the camera view. The model chose the meaning; this file chooses the visuals:
/// one action colour, red only for danger, green only for verified, and a distinct shape for each.
final class OverlayView: UIView {
    static let action = UIColor(red: 0.25, green: 0.95, blue: 1, alpha: 1)
    static let danger = UIColor(red: 1, green: 0.27, blue: 0.23, alpha: 1)
    static let verified = UIColor(red: 0.2, green: 0.85, blue: 0.35, alpha: 1)

    private let dangerBanner = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        dangerBanner.textColor = .white
        dangerBanner.backgroundColor = Self.danger.withAlphaComponent(0.9)
        dangerBanner.font = .systemFont(ofSize: 17, weight: .semibold)
        dangerBanner.textAlignment = .center
        dangerBanner.numberOfLines = 2
        dangerBanner.layer.cornerRadius = 12
        dangerBanner.layer.masksToBounds = true
        dangerBanner.isHidden = true
        addSubview(dangerBanner)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Marks whose object moved in the image: drawn where the object is now (see ImageFollower).
    var adjust: [Int: ImageFollower.Adjust] = [:]

    func render(_ annotations: [AnnotationBoard.Annotation], now: TimeInterval, marks: [Int: AnchoredMark], project base: @escaping (simd_float3) -> CGPoint?) {
        // Each mark's projection: from its room anchor, moved on screen when its object moved.
        let adjust = self.adjust
        func proj(_ mark: AnchoredMark?) -> (simd_float3) -> CGPoint? {
            guard let mark, let a = adjust[mark.id] else { return base }
            if a.hidden { return { _ in nil } }
            return { w in base(w).map { CGPoint(x: a.to.x + ($0.x - a.from.x) * a.scale, y: a.to.y + ($0.y - a.from.y) * a.scale) } }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayers?.filter { $0 !== dangerBanner.layer }.forEach { $0.removeFromSuperlayer() }
        var generalDanger: String?

        var hinted = Set<Int>()
        for a in annotations {
            let alpha = opacity(a, now: now)
            // Off screen: a wedge at the edge points the way back, for every kind of cue.
            if let first = a.cue.marks.first, let mark = marks[first],
               !a.cue.marks.contains(where: { screenPolygons(marks[$0], proj(marks[$0])) != nil }) {
                if case .danger(_, let reason) = a.cue { generalDanger = reason }
                if hinted.insert(first).inserted {
                    edgeHint(mark, proj(mark), color: { if case .danger = a.cue { return Self.danger } else { return Self.action } }(), force: true)
                }
                continue
            }
            switch a.cue {
            case .outline(let m):
                if let p = screenPolygons(marks[m], proj(marks[m])) { highlight(p, pop: pop(a, now), alpha: alpha, fill: 0.10) }
                else { edgeHint(marks[m], proj(marks[m]), color: Self.action) }
            case .candidates(let ms):
                for (i, m) in ms.enumerated() {
                    guard let p = screenPolygons(marks[m], proj(marks[m])) else { continue }
                    stroke(p, color: .white, width: 2.5, alpha: alpha, dash: [8, 6])
                    if let c = marks[m].flatMap({ proj($0)($0.centroid) }) { badge("\(i + 1)", at: c, color: .white, alpha: alpha) }
                }
            case .ring(let m, let label):
                guard let mark = marks[m] else { continue }
                guard let p = screenPolygons(mark, proj(mark)) else { edgeHint(mark, proj(mark), color: Self.action); continue }
                // A small target: the contour itself, tinted, with its step number above it.
                highlight(p, pop: pop(a, now), alpha: alpha, fill: 0.22)
                if let label {
                    let b = bounds(p)
                    let tag = CGPoint(x: b.midX, y: b.minY - 26)
                    leader(from: CGPoint(x: b.midX, y: b.minY - 2), to: CGPoint(x: tag.x, y: tag.y + 12), alpha: alpha)
                    stepBadge(label, at: tag, alpha: alpha)
                }
            case .move(let m, let dir):
                guard let mark = marks[m] else { continue }
                if let p = screenPolygons(mark, proj(mark)) { stroke(p, color: Self.action, width: 3, alpha: alpha * 0.8) }
                if dir == .in || dir == .out {
                    if let c = proj(mark)(mark.centroid) { ring(at: c, radius: 22, color: Self.action, alpha: alpha) }
                } else {
                    let (s, e) = mark.arrow(dir)
                    if let a0 = proj(mark)(s), let a1 = proj(mark)(e) { arrow(from: a0, to: a1, color: Self.action, alpha: alpha) }
                }
            case .rotate(let m, let dir, _):
                guard let mark = marks[m], let c = proj(mark)(mark.centroid) else { continue }
                let r = max(26, (screenPolygons(mark, proj(mark)).map { bounds($0) }?.width ?? 40) * 0.55)
                rotation(at: c, radius: r, clockwise: dir == .cw, color: Self.action, alpha: alpha)
            case .place(let m):
                if let p = screenPolygons(marks[m], proj(marks[m])) { stroke(p, color: Self.action, width: 3, alpha: alpha, dash: [12, 8]) }
            case .sequence(let ms):
                for (i, m) in ms.enumerated() {
                    guard let mark = marks[m], let c = proj(mark)(mark.centroid) else { continue }
                    if let p = screenPolygons(mark, proj(mark)) { stroke(p, color: Self.action, width: i == 0 ? 3.5 : 2, alpha: alpha * (i == 0 ? 1 : 0.5)) }
                    badge("\(i + 1)", at: c, color: Self.action, alpha: alpha * (i == 0 ? 1 : 0.6))
                }
            case .danger(let m, let reason):
                if let m, let p = screenPolygons(marks[m], proj(marks[m])) {
                    fill(p, color: Self.danger, alpha: 0.28)
                    stroke(p, color: Self.danger, width: 4, alpha: 1)
                    if let c = marks[m].flatMap({ proj($0)($0.centroid) }) { badge("!", at: c, color: Self.danger, alpha: 1) }
                }
                generalDanger = reason
            case .landmark(let m, let name):
                guard let mark = marks[m], let p = screenPolygons(mark, proj(mark)) else { continue }
                highlight(p, pop: pop(a, now), alpha: alpha, fill: 0.15)
                let b = bounds(p)
                stepBadge(name, at: CGPoint(x: b.midX, y: b.minY - 22), alpha: alpha)
            case .offscreen(let m):
                edgeHint(marks[m], proj(marks[m]), color: Self.action, force: true)
            case .verified(let m):
                guard let mark = marks[m] else { continue }
                if let p = screenPolygons(mark, proj(mark)) { stroke(p, color: Self.verified, width: 4, alpha: alpha) }
                if let c = proj(mark)(mark.centroid) { badge("✓", at: c, color: Self.verified, alpha: alpha) }
            case .clear, .state, .locate, .needView, .remember, .task, .readPages, .find, .list:
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

    // MARK: Lifetimes

    /// Fades in over 0.25 s; transient cues fade out over their last 0.6 s.
    private func opacity(_ a: AnnotationBoard.Annotation, now: TimeInterval) -> CGFloat {
        let fadeIn = min(1, (now - a.shownAt) / 0.25)
        if case .transient(let until) = a.lifetime {
            return CGFloat(fadeIn * min(1, max(0, (until - now) / 0.6)))
        }
        return CGFloat(fadeIn)
    }

    /// A short "pop" when a cue appears: 1 → 0 over about 0.4 s.
    private func pop(_ a: AnnotationBoard.Annotation, _ now: TimeInterval) -> CGFloat {
        CGFloat(exp(-max(0, now - a.shownAt) * 8))
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

    private func bounds(_ polys: [[CGPoint]]) -> CGRect {
        let pts = polys.flatMap { $0 }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    // MARK: Shapes

    private func shape(_ path: UIBezierPath, stroke: UIColor?, fill: UIColor?, width: CGFloat, alpha: CGFloat, dash: [NSNumber]? = nil) {
        let l = CAShapeLayer()
        l.path = path.cgPath
        l.strokeColor = stroke?.cgColor
        l.fillColor = fill?.cgColor ?? UIColor.clear.cgColor
        l.lineWidth = width
        l.lineJoin = .round
        l.lineCap = .round
        l.lineDashPattern = dash
        l.opacity = Float(alpha)
        layer.addSublayer(l)
    }

    private func polygonPath(_ polys: [[CGPoint]]) -> UIBezierPath {
        let path = UIBezierPath()
        for ring in polys {
            guard let first = ring.first else { continue }
            path.move(to: first)
            ring.dropFirst().forEach { path.addLine(to: $0) }
            path.close()
        }
        return path
    }

    private func stroke(_ polys: [[CGPoint]], color: UIColor, width: CGFloat, alpha: CGFloat, dash: [NSNumber]? = nil) {
        shape(polygonPath(polys), stroke: color, fill: nil, width: width, alpha: alpha, dash: dash)
    }

    /// The pointer: a thin, crisp line on the object's edge, a dark rim for contrast on any
    /// background, and a faint tint inside that briefly brightens when the cue appears.
    private func highlight(_ polys: [[CGPoint]], pop: CGFloat, alpha: CGFloat, fill tint: CGFloat) {
        let path = polygonPath(polys).cgPath
        let fill = CAShapeLayer()
        fill.path = path
        fill.fillColor = Self.action.withAlphaComponent(tint + 0.25 * pop).cgColor
        fill.strokeColor = UIColor.black.withAlphaComponent(0.45).cgColor
        fill.lineWidth = 4.5
        fill.lineJoin = .round
        fill.opacity = Float(alpha)
        layer.addSublayer(fill)
        let core = CAShapeLayer()
        core.path = path
        core.fillColor = UIColor.clear.cgColor
        core.strokeColor = UIColor(red: 0.55, green: 1, blue: 1, alpha: 1).cgColor
        core.lineWidth = 2
        core.lineJoin = .round
        core.opacity = Float(alpha)
        layer.addSublayer(core)
    }

    private func leader(from a: CGPoint, to b: CGPoint, alpha: CGFloat) {
        let path = UIBezierPath()
        path.move(to: a)
        path.addLine(to: b)
        shape(path, stroke: UIColor.white.withAlphaComponent(0.9), fill: nil, width: 1.5, alpha: alpha)
    }

    /// A round step number ("1", "2") in the action colour.
    private func stepBadge(_ text: String, at c: CGPoint, alpha: CGFloat) {
        let l = CATextLayer()
        l.string = text
        l.font = UIFont.systemFont(ofSize: 16, weight: .heavy)
        l.fontSize = 16
        l.alignmentMode = .center
        l.foregroundColor = UIColor.black.cgColor
        l.backgroundColor = Self.action.cgColor
        l.contentsScale = traitCollection.displayScale
        let w = max(26, CGFloat(text.count) * 9 + 18)
        l.frame = CGRect(x: c.x - w / 2, y: c.y - 13, width: w, height: 26)
        l.cornerRadius = 13
        l.borderColor = UIColor.white.cgColor
        l.borderWidth = 1.5
        l.opacity = Float(alpha)
        layer.addSublayer(l)
    }

    private func fill(_ polys: [[CGPoint]], color: UIColor, alpha: CGFloat) {
        shape(polygonPath(polys), stroke: nil, fill: color.withAlphaComponent(alpha), width: 0, alpha: 1)
    }

    private func ring(at c: CGPoint, radius r: CGFloat, color: UIColor, alpha: CGFloat) {
        shape(UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), stroke: color, fill: nil, width: 4, alpha: alpha)
    }

    private func arrow(from a: CGPoint, to b: CGPoint, color: UIColor, alpha: CGFloat) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(1, hypot(dx, dy))
        let ux = dx / len, uy = dy / len
        let head: CGFloat = min(26, len * 0.4)
        let path = UIBezierPath()
        path.move(to: a)
        path.addLine(to: CGPoint(x: b.x - ux * head * 0.6, y: b.y - uy * head * 0.6))
        shape(path, stroke: color, fill: nil, width: 7, alpha: alpha)
        let tip = UIBezierPath()
        tip.move(to: b)
        tip.addLine(to: CGPoint(x: b.x - ux * head - uy * head * 0.6, y: b.y - uy * head + ux * head * 0.6))
        tip.addLine(to: CGPoint(x: b.x - ux * head + uy * head * 0.6, y: b.y - uy * head - ux * head * 0.6))
        tip.close()
        shape(tip, stroke: nil, fill: color, width: 0, alpha: alpha)
    }

    private func rotation(at c: CGPoint, radius r: CGFloat, clockwise: Bool, color: UIColor, alpha: CGFloat) {
        let start: CGFloat = -.pi * 0.9
        let end: CGFloat = start + .pi * 1.5 * (clockwise ? 1 : -1)
        let path = UIBezierPath(arcCenter: c, radius: r, startAngle: start, endAngle: end, clockwise: clockwise)
        shape(path, stroke: color, fill: nil, width: 6, alpha: alpha)
        let tipPoint = CGPoint(x: c.x + r * cos(end), y: c.y + r * sin(end))
        // Tangent direction at the end of the arc.
        let t: CGFloat = clockwise ? 1 : -1
        let ux = -sin(end) * t, uy = cos(end) * t
        let head: CGFloat = 18
        let tip = UIBezierPath()
        tip.move(to: CGPoint(x: tipPoint.x + ux * head * 0.6, y: tipPoint.y + uy * head * 0.6))
        tip.addLine(to: CGPoint(x: tipPoint.x - ux * head * 0.4 - uy * head * 0.6, y: tipPoint.y - uy * head * 0.4 + ux * head * 0.6))
        tip.addLine(to: CGPoint(x: tipPoint.x - ux * head * 0.4 + uy * head * 0.6, y: tipPoint.y - uy * head * 0.4 - ux * head * 0.6))
        tip.close()
        shape(tip, stroke: nil, fill: color, width: 0, alpha: alpha)
    }

    private func badge(_ text: String, at c: CGPoint, color: UIColor, alpha: CGFloat) {
        let l = CATextLayer()
        l.string = text
        l.fontSize = 17
        l.font = UIFont.systemFont(ofSize: 17, weight: .bold)
        l.alignmentMode = .center
        l.foregroundColor = UIColor.black.cgColor
        l.backgroundColor = color.cgColor
        l.contentsScale = traitCollection.displayScale
        let w = max(28, CGFloat(text.count) * 11 + 14)
        l.frame = CGRect(x: c.x - w / 2, y: c.y - 14, width: w, height: 28)
        l.cornerRadius = 14
        l.opacity = Float(alpha)
        layer.addSublayer(l)
    }

    /// A wedge at the screen edge pointing at a mark that is out of view.
    private func edgeHint(_ mark: AnchoredMark?, _ project: (simd_float3) -> CGPoint?, color: UIColor, force: Bool = false) {
        guard let mark, let p = project(mark.centroid) else { return }
        let inner = bounds.insetBy(dx: 28, dy: 60)
        if inner.contains(p), !force { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let dx = p.x - c.x, dy = p.y - c.y
        let t = min(inner.width / 2 / max(abs(dx), 1), inner.height / 2 / max(abs(dy), 1), 1)
        let edge = CGPoint(x: c.x + dx * t, y: c.y + dy * t)
        let len = max(1, hypot(dx, dy))
        arrow(from: CGPoint(x: edge.x - dx / len * 40, y: edge.y - dy / len * 40), to: edge, color: color, alpha: 1)
    }
}
