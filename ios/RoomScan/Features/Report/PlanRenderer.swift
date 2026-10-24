import UIKit

/// Core Graphics drawing of a floor plan / wall elevation — used for PDF reports (no SwiftUI needed).
enum PlanRenderer {

    // MARK: Floor plan

    /// Draws `plan` fitted into `rect` (dimension lines included) on the current UIKit context.
    static func drawPlan(_ plan: FloorPlan, in rect: CGRect, ctx: CGContext, ink: UIColor = .black, accent: UIColor = UIColor(red: 0, green: 0.42, blue: 0.9, alpha: 1)) {
        guard plan.wallCount >= 3 else { return }
        let b = plan.bounds
        let w = max(b.max.x - b.min.x, 0.5), h = max(b.max.y - b.min.y, 0.5)
        let pad: CGFloat = 54                      // room for dimension lines
        let scale = min((rect.width - 2 * pad) / w, (rect.height - 2 * pad) / h)
        let cx = (b.min.x + b.max.x) / 2, cy = (b.min.y + b.max.y) / 2
        func S(_ p: PlanPoint) -> CGPoint { CGPoint(x: rect.midX + (p.x - cx) * scale, y: rect.midY + (p.y - cy) * scale) }
        let wallPx = max(plan.wallThickness * scale, 2.5)

        ctx.saveGState()
        // floor
        let outline = CGMutablePath()
        outline.move(to: S(plan.corners[0])); for c in plan.corners.dropFirst() { outline.addLine(to: S(c)) }; outline.closeSubpath()
        ctx.addPath(outline); ctx.setFillColor(ink.withAlphaComponent(0.035).cgColor); ctx.fillPath()

        // objects
        for o in plan.objects {
            let c = S(o.center), ow = o.width * scale, od = o.depth * scale
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y); ctx.rotate(by: o.rotation)
            let r = CGRect(x: -ow / 2, y: -od / 2, width: ow, height: od)
            ctx.setFillColor(ink.withAlphaComponent(0.06).cgColor); ctx.fill(r)
            ctx.setStrokeColor(ink.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.7); ctx.stroke(r)
            ctx.restoreGState()
            if ow > 30 && od > 18 {
                text(o.category.capitalized, at: CGPoint(x: c.x, y: c.y - 5), size: 7, color: ink.withAlphaComponent(0.7), bold: true)
                text("\(Measure.ftIn(o.width)) × \(Measure.ftIn(o.depth))", at: CGPoint(x: c.x, y: c.y + 5), size: 6, color: ink.withAlphaComponent(0.6))
            }
        }

        // walls
        ctx.setLineCap(.square)
        for i in 0..<plan.wallCount {
            let a = S(plan.wallStart(i)), e = S(plan.wallEnd(i))
            ctx.move(to: a); ctx.addLine(to: e)
            if plan.isInferred(i) {
                ctx.setLineWidth(max(wallPx * 0.45, 1)); ctx.setStrokeColor(ink.withAlphaComponent(0.45).cgColor); ctx.setLineDash(phase: 0, lengths: [5, 4])
            } else {
                ctx.setLineWidth(wallPx); ctx.setStrokeColor(ink.cgColor); ctx.setLineDash(phase: 0, lengths: [])
            }
            ctx.strokePath()
        }
        ctx.setLineDash(phase: 0, lengths: [])

        // openings
        for o in plan.openings {
            let a = S(plan.point(onWall: o.wall, at: o.left)), e = S(plan.point(onWall: o.wall, at: o.right))
            let len = hypot(e.x - a.x, e.y - a.y), ang = atan2(e.y - a.y, e.x - a.x)
            let inward: CGFloat = plan.inwardNormal(o.wall).dot(plan.wallDirection(o.wall).perp) > 0 ? 1 : -1
            ctx.saveGState()
            ctx.translateBy(x: a.x, y: a.y); ctx.rotate(by: ang)
            ctx.setFillColor(UIColor.white.cgColor); ctx.fill(CGRect(x: 0, y: -wallPx / 2 - 1, width: len, height: wallPx + 2))
            ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(1)
            switch o.kind {
            case .door:
                ctx.move(to: .zero); ctx.addLine(to: CGPoint(x: 0, y: inward * len)); ctx.strokePath()
                ctx.setLineWidth(0.5)
                ctx.addArc(center: .zero, radius: len, startAngle: 0, endAngle: inward * .pi / 2, clockwise: inward < 0); ctx.strokePath()
            case .window:
                ctx.setFillColor(accent.withAlphaComponent(0.18).cgColor); ctx.fill(CGRect(x: 0, y: -wallPx / 3, width: len, height: 2 * wallPx / 3))
                ctx.setLineWidth(0.6)
                for yy in [-wallPx / 3, 0, wallPx / 3] { ctx.move(to: CGPoint(x: 0, y: yy)); ctx.addLine(to: CGPoint(x: len, y: yy)) }
                ctx.strokePath()
            case .opening:
                ctx.setLineDash(phase: 0, lengths: [3, 2]); ctx.setLineWidth(0.6)
                for yy in [-wallPx / 2, wallPx / 2] { ctx.move(to: CGPoint(x: 0, y: yy)); ctx.addLine(to: CGPoint(x: len, y: yy)) }
                ctx.strokePath(); ctx.setLineDash(phase: 0, lengths: [])
            }
            ctx.setLineWidth(1.2)
            for xx in [0, len] { ctx.move(to: CGPoint(x: xx, y: -wallPx / 2)); ctx.addLine(to: CGPoint(x: xx, y: wallPx / 2)) }
            ctx.strokePath()
            ctx.restoreGState()
        }

        // dimensions: walls (outside), opening widths (closer), overall when it differs
        let half = Double(wallPx / 2 / scale)
        for i in 0..<plan.wallCount {
            let n = plan.outwardNormal(i)
            let hasOpen = !plan.openings(on: i).isEmpty
            let off = half + Double((hasOpen ? 30 : 14) / scale)
            dimension(from: S(plan.wallStart(i) + n * off), to: S(plan.wallEnd(i) + n * off), label: Measure.ftIn(plan.wallLength(i)),
                      ext: (S(plan.wallStart(i) + n * half), S(plan.wallEnd(i) + n * half)), ctx: ctx, color: ink, accent: accent)
            for o in plan.openings(on: i) {
                let off2 = half + Double(12 / scale)
                dimension(from: S(plan.point(onWall: i, at: o.left) + n * off2), to: S(plan.point(onWall: i, at: o.right) + n * off2),
                          label: Measure.ftIn(o.width), ext: nil, ctx: ctx, color: ink, accent: accent, small: true)
                if o.left > 0.05 {
                    dimension(from: S(plan.point(onWall: i, at: 0) + n * off2), to: S(plan.point(onWall: i, at: o.left) + n * off2),
                              label: Measure.ftIn(o.left), ext: nil, ctx: ctx, color: ink, accent: accent, small: true)
                }
            }
        }
        ctx.restoreGState()
    }

    // MARK: Wall elevation

    static func drawElevation(_ plan: FloorPlan, wall i: Int, in rect: CGRect, ctx: CGContext, ink: UIColor = .black, accent: UIColor = UIColor(red: 0, green: 0.42, blue: 0.9, alpha: 1)) {
        let L = plan.wallLength(i), H = plan.wallHeight
        let pad: CGFloat = 26
        let scale = min((rect.width - 2 * pad) / L, (rect.height - 2 * pad) / H)
        let wr = CGRect(x: rect.midX - L * scale / 2, y: rect.midY - H * scale / 2, width: L * scale, height: H * scale)
        ctx.saveGState()
        ctx.setFillColor(ink.withAlphaComponent(0.04).cgColor); ctx.fill(wr)
        ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(1); ctx.stroke(wr)
        for o in plan.openings(on: i) {
            let r = CGRect(x: wr.minX + o.left * scale, y: wr.maxY - (o.sill + o.height) * scale, width: o.width * scale, height: o.height * scale)
            ctx.setFillColor((o.kind == .window ? accent.withAlphaComponent(0.15) : ink.withAlphaComponent(0.08)).cgColor); ctx.fill(r)
            ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(0.8); ctx.stroke(r)
            if o.kind == .window { ctx.move(to: CGPoint(x: r.midX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.midX, y: r.maxY)); ctx.strokePath() }
            dimension(from: CGPoint(x: r.minX, y: r.maxY + 8), to: CGPoint(x: r.maxX, y: r.maxY + 8), label: Measure.ftIn(o.width), ext: nil, ctx: ctx, color: ink, accent: accent, small: true)
            dimension(from: CGPoint(x: r.maxX + 8, y: r.maxY), to: CGPoint(x: r.maxX + 8, y: r.minY), label: Measure.ftIn(o.height), ext: nil, ctx: ctx, color: ink, accent: accent, small: true)
            if o.sill > 0.02 {
                dimension(from: CGPoint(x: r.minX - 8, y: wr.maxY), to: CGPoint(x: r.minX - 8, y: r.maxY), label: Measure.ftIn(o.sill), ext: nil, ctx: ctx, color: ink, accent: accent, small: true)
            }
        }
        dimension(from: CGPoint(x: wr.minX, y: wr.maxY + 18), to: CGPoint(x: wr.maxX, y: wr.maxY + 18), label: Measure.ftIn(L), ext: nil, ctx: ctx, color: ink, accent: accent)
        dimension(from: CGPoint(x: wr.minX - 18, y: wr.maxY), to: CGPoint(x: wr.minX - 18, y: wr.minY), label: Measure.ftIn(H), ext: nil, ctx: ctx, color: ink, accent: accent)
        ctx.restoreGState()
    }

    // MARK: Helpers

    private static func dimension(from a: CGPoint, to b: CGPoint, label: String, ext: (CGPoint, CGPoint)?, ctx: CGContext, color: UIColor, accent: UIColor, small: Bool = false) {
        let len = hypot(b.x - a.x, b.y - a.y); guard len > 1 else { return }
        let ang = atan2(b.y - a.y, b.x - a.x)
        ctx.saveGState()
        ctx.setStrokeColor(color.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(0.5)
        if let ext {
            ctx.setLineDash(phase: 0, lengths: [1.5, 1.5])
            ctx.move(to: ext.0); ctx.addLine(to: a); ctx.move(to: ext.1); ctx.addLine(to: b); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        ctx.translateBy(x: a.x, y: a.y); ctx.rotate(by: ang)
        ctx.move(to: .zero); ctx.addLine(to: CGPoint(x: len, y: 0))
        for xx in [0, len] { ctx.move(to: CGPoint(x: xx, y: -3)); ctx.addLine(to: CGPoint(x: xx, y: 3)) }
        ctx.strokePath()
        var a2 = ang; if a2 > .pi / 2 { a2 -= .pi } else if a2 < -.pi / 2 { a2 += .pi }
        ctx.rotate(by: a2 - ang)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.translateBy(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2); ctx.rotate(by: a2)
        let font = UIFont.systemFont(ofSize: small ? 6.5 : 7.5, weight: .medium)
        let size = (label as NSString).size(withAttributes: [.font: font])
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(x: -size.width / 2 - 2, y: -size.height / 2, width: size.width + 4, height: size.height))
        (label as NSString).draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: [.font: font, .foregroundColor: accent])
        ctx.restoreGState()
    }

    static func text(_ s: String, at p: CGPoint, size: CGFloat, color: UIColor, bold: Bool = false) {
        let font = bold ? UIFont.systemFont(ofSize: size, weight: .semibold) : UIFont.systemFont(ofSize: size)
        let sz = (s as NSString).size(withAttributes: [.font: font])
        (s as NSString).draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2), withAttributes: [.font: font, .foregroundColor: color])
    }
}
