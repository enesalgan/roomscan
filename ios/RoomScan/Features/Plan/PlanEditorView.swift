import SwiftUI

enum PlanSelection: Hashable {
    case wall(Int)
    case corner(Int)
    case opening(UUID)
    case object(UUID)
}

/// Top-down editable floor plan: pan/zoom, drag corners, drag openings along walls, drag objects,
/// tap to select; dimension lines on every wall, overall size, object sizes.
struct PlanEditorView: View {
    @Binding var plan: FloorPlan
    @Binding var selection: PlanSelection?
    var onBeginEdit: () -> Void
    var onEndEdit: () -> Void
    var refitToken: Int = 0                         // bump to re-fit the view (e.g. after "Square up")

    @State private var scale: CGFloat = 60          // points per meter
    @State private var baseScale: CGFloat = 60
    @State private var origin: CGPoint = .zero      // screen position of plan (0,0)
    @State private var didFit = false
    @State private var drag: DragTarget?

    private enum DragTarget { case corner(Int), opening(UUID), object(UUID, PlanPoint), pan(CGPoint) }

    private var ink: Color { Color(.label) }
    private var dim: Color { Color.accentColor }
    private var paper: Color { Color(.systemBackground) }

    var body: some View {
        GeometryReader { geo in
            Canvas(rendersAsynchronously: false) { ctx, size in draw(&ctx, size: size) }
                .background(Color(.systemGroupedBackground))
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { v in scale = min(max(baseScale * v.magnification, 15), 400) }
                        .onEnded { _ in baseScale = scale }
                )
                .onTapGesture { loc in selection = hitTest(loc) }
                .onAppear { if !didFit { fit(in: geo.size); didFit = true } }
                .onChange(of: refitToken) { _, _ in withAnimation { fit(in: geo.size) } }
                .overlay(alignment: .bottomTrailing) {
                    Button { withAnimation { fit(in: geo.size) } } label: {
                        Image(systemName: "arrow.down.left.and.arrow.up.right").font(.body.weight(.semibold)).padding(10)
                            .background(.regularMaterial, in: Circle())
                    }
                    .padding(12)
                }
        }
    }

    // MARK: Transform

    private func toScreen(_ p: PlanPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
    private func toPlan(_ s: CGPoint) -> PlanPoint { PlanPoint(x: (s.x - origin.x) / scale, y: (s.y - origin.y) / scale) }

    private func fit(in size: CGSize) {
        let b = plan.bounds
        let w = max(b.max.x - b.min.x, 0.5), h = max(b.max.y - b.min.y, 0.5)
        scale = min((size.width - 150) / w, (size.height - 170) / h)
        scale = min(max(scale, 15), 400)
        baseScale = scale
        let center = PlanPoint(x: (b.min.x + b.max.x) / 2, y: (b.min.y + b.max.y) / 2)
        origin = CGPoint(x: size.width / 2 - center.x * scale, y: size.height / 2 - center.y * scale)
    }

    private var wallPx: CGFloat { max(plan.wallThickness * scale, 5) }

    // MARK: Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { v in
                if drag == nil {
                    switch hitTest(v.startLocation) {
                    case .corner(let i): drag = .corner(i); onBeginEdit()
                    case .opening(let id): drag = .opening(id); onBeginEdit()
                    case .object(let id):
                        if let o = plan.objects.first(where: { $0.id == id }) { drag = .object(id, o.center); onBeginEdit() }
                        else { drag = .pan(origin) }
                    default: drag = .pan(origin)
                    }
                }
                switch drag! {
                case .corner(let i):
                    plan.moveCorner(i, to: snap(toPlan(v.location)))
                case .opening(let id):
                    guard let k = plan.openings.firstIndex(where: { $0.id == id }) else { return }
                    let o = plan.openings[k]
                    let t = (toPlan(v.location) - plan.wallStart(o.wall)).dot(plan.wallDirection(o.wall))
                    let half = o.width / 2
                    plan.openings[k].offset = snap(min(max(t, half), max(half, plan.wallLength(o.wall) - half)))
                case .object(let id, let start):
                    guard let k = plan.objects.firstIndex(where: { $0.id == id }) else { return }
                    plan.objects[k].center = snap(start + PlanPoint(x: v.translation.width / scale, y: v.translation.height / scale))
                case .pan(let start):
                    origin = CGPoint(x: start.x + v.translation.width, y: start.y + v.translation.height)
                }
            }
            .onEnded { _ in
                if case .pan(_)? = drag {} else { onEndEdit() }
                drag = nil
            }
    }

    private func snap(_ p: PlanPoint) -> PlanPoint { PlanPoint(x: snap(p.x), y: snap(p.y)) }
    private func snap(_ v: Double) -> Double { (v / 0.00635).rounded() * 0.00635 }   // 1/4 inch

    // MARK: Hit testing

    private func hitTest(_ s: CGPoint) -> PlanSelection? {
        for i in 0..<plan.wallCount {
            let c = toScreen(plan.corners[i])
            if hypot(c.x - s.x, c.y - s.y) < 16 { return .corner(i) }
        }
        for o in plan.openings {
            let (a, b) = openingSegment(o)
            if distance(s, toScreen(a), toScreen(b)) < max(wallPx, 16) { return .opening(o.id) }
        }
        for i in 0..<plan.wallCount {
            if distance(s, toScreen(plan.wallStart(i)), toScreen(plan.wallEnd(i))) < max(wallPx, 14) { return .wall(i) }
        }
        for o in plan.objects.reversed() {
            let c = toScreen(o.center)
            // rotate point into object space
            let dx = s.x - c.x, dy = s.y - c.y
            let lx = dx * cos(-o.rotation) - dy * sin(-o.rotation)
            let ly = dx * sin(-o.rotation) + dy * cos(-o.rotation)
            if abs(lx) <= o.width * scale / 2 + 4 && abs(ly) <= o.depth * scale / 2 + 4 { return .object(o.id) }
        }
        return nil
    }

    private func openingSegment(_ o: PlanOpening) -> (PlanPoint, PlanPoint) {
        (plan.point(onWall: o.wall, at: o.left), plan.point(onWall: o.wall, at: o.right))
    }

    private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let len2 = ab.x * ab.x + ab.y * ab.y
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2, 0), 1)
        return hypot(p.x - (a.x + ab.x * t), p.y - (a.y + ab.y * t))
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        drawDotGrid(&ctx, size: size)
        guard plan.wallCount >= 3 else { return }

        var outline = Path()
        outline.move(to: toScreen(plan.corners[0]))
        for c in plan.corners.dropFirst() { outline.addLine(to: toScreen(c)) }
        outline.closeSubpath()

        // Floor + subtle 1 ft grid
        ctx.fill(outline, with: .color(paper))
        drawFloorGrid(&ctx, clip: outline)

        // Objects
        for o in plan.objects { drawObject(&ctx, o) }

        // Walls — one closed path so corners are mitered cleanly
        ctx.stroke(outline, with: .color(ink), style: StrokeStyle(lineWidth: wallPx, lineJoin: .miter))
        if case .wall(let i) = selection {
            var p = Path(); p.move(to: toScreen(plan.wallStart(i))); p.addLine(to: toScreen(plan.wallEnd(i)))
            ctx.stroke(p, with: .color(dim), style: StrokeStyle(lineWidth: wallPx, lineCap: .butt))
        }

        // Openings
        for o in plan.openings { drawOpening(&ctx, o) }

        // Corner handles
        for i in 0..<plan.wallCount {
            let c = toScreen(plan.corners[i])
            let sel = selection == .corner(i)
            let r: CGFloat = sel ? 7 : 4
            let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.fill(circle, with: .color(sel ? dim : .white))
            ctx.stroke(circle, with: .color(sel ? dim : ink), lineWidth: 1.5)
        }

        // Wall dimension lines (outside the room)
        for i in 0..<plan.wallCount {
            let n = plan.outwardNormal(i)
            let off = Double((wallPx / 2 + 26) / scale)
            let a = plan.wallStart(i) + n * off, b = plan.wallEnd(i) + n * off
            let sel = selection == .wall(i)
            dimensionLine(&ctx, from: toScreen(a), to: toScreen(b), text: Measure.ftIn(plan.wallLength(i)),
                          color: sel ? dim : .secondary, emphasized: sel,
                          extFrom: toScreen(plan.wallStart(i) + n * Double(wallPx / 2 / scale)),
                          extTo: toScreen(plan.wallEnd(i) + n * Double(wallPx / 2 / scale)))
        }

        // Overall size (top + left) — only when no single wall already shows that length
        let b = plan.bounds
        let offAll = Double((wallPx / 2 + 62) / scale)
        let hasWall = { (len: Double, horizontal: Bool) -> Bool in
            (0..<plan.wallCount).contains { i in
                let d = plan.wallDirection(i)
                let isH = abs(d.x) > abs(d.y)
                return isH == horizontal && abs(plan.wallLength(i) - len) < 0.02
            }
        }
        if !hasWall(plan.width, true) {
            dimensionLine(&ctx, from: toScreen(PlanPoint(x: b.min.x, y: b.min.y - offAll)), to: toScreen(PlanPoint(x: b.max.x, y: b.min.y - offAll)),
                          text: Measure.ftIn(plan.width), color: .secondary, emphasized: false, extFrom: nil, extTo: nil)
        }
        if !hasWall(plan.depth, false) {
            dimensionLine(&ctx, from: toScreen(PlanPoint(x: b.min.x - offAll, y: b.max.y)), to: toScreen(PlanPoint(x: b.min.x - offAll, y: b.min.y)),
                          text: Measure.ftIn(plan.depth), color: .secondary, emphasized: false, extFrom: nil, extTo: nil)
        }

        // Opening dimensions (always visible; emphasized when selected)
        for o in plan.openings {
            let emphasized = selection == .opening(o.id) || selection == .wall(o.wall)
            drawOpeningDims(&ctx, o, emphasized: emphasized)
        }
    }

    private func drawDotGrid(_ ctx: inout GraphicsContext, size: CGSize) {
        let step = scale * 0.3048
        guard step > 8 else { return }
        var dots = Path()
        var x = origin.x.truncatingRemainder(dividingBy: step); if x < 0 { x += step }
        var y0 = origin.y.truncatingRemainder(dividingBy: step); if y0 < 0 { y0 += step }
        while x < size.width {
            var y = y0
            while y < size.height { dots.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)); y += step }
            x += step
        }
        ctx.fill(dots, with: .color(.secondary.opacity(0.4)))
    }

    private func drawFloorGrid(_ ctx: inout GraphicsContext, clip: Path) {
        let step = scale * 0.3048
        guard step > 10 else { return }
        var g = ctx
        g.clip(to: clip)
        var lines = Path()
        let bb = clip.boundingRect
        var x = origin.x + ((bb.minX - origin.x) / step).rounded(.down) * step
        while x < bb.maxX { lines.move(to: CGPoint(x: x, y: bb.minY)); lines.addLine(to: CGPoint(x: x, y: bb.maxY)); x += step }
        var y = origin.y + ((bb.minY - origin.y) / step).rounded(.down) * step
        while y < bb.maxY { lines.move(to: CGPoint(x: bb.minX, y: y)); lines.addLine(to: CGPoint(x: bb.maxX, y: y)); y += step }
        g.stroke(lines, with: .color(.orange.opacity(0.10)), lineWidth: 0.5)
    }

    private func drawOpening(_ ctx: inout GraphicsContext, _ o: PlanOpening) {
        let (a, b) = openingSegment(o)
        let sa = toScreen(a), sb = toScreen(b)
        let len = hypot(sb.x - sa.x, sb.y - sa.y)
        let angle = atan2(sb.y - sa.y, sb.x - sa.x)
        let inwardSign: CGFloat = plan.inwardNormal(o.wall).dot(plan.wallDirection(o.wall).perp) > 0 ? 1 : -1
        let selected = selection == .opening(o.id)
        let t = wallPx
        let stroke = selected ? dim : ink

        ctx.drawLayer { l in
            l.translateBy(x: sa.x, y: sa.y)
            l.rotate(by: .radians(angle))
            l.fill(Path(CGRect(x: 0, y: -t / 2 - 3.5, width: len, height: t + 7)), with: .color(paper))   // cut the wall
            switch o.kind {
            case .door:
                var leaf = Path()
                leaf.move(to: .zero); leaf.addLine(to: CGPoint(x: 0, y: inwardSign * len))
                var arc = Path()
                arc.move(to: CGPoint(x: len, y: 0))
                for k in 1...16 {
                    let a = Double(k) / 16 * .pi / 2
                    arc.addLine(to: CGPoint(x: len * cos(a), y: inwardSign * len * sin(a)))
                }
                l.stroke(leaf, with: .color(stroke), lineWidth: 2.5)
                l.stroke(arc, with: .color(stroke.opacity(0.7)), lineWidth: 1)
            case .window:
                l.fill(Path(CGRect(x: 0, y: -t / 3, width: len, height: 2 * t / 3)), with: .color(.cyan.opacity(0.22)))
                var lines = Path()
                for yy in [-t / 3, 0, t / 3] { lines.move(to: CGPoint(x: 0, y: yy)); lines.addLine(to: CGPoint(x: len, y: yy)) }
                l.stroke(lines, with: .color(stroke), lineWidth: 1.2)
            case .opening:
                var dashed = Path()
                dashed.move(to: CGPoint(x: 0, y: -t / 2)); dashed.addLine(to: CGPoint(x: len, y: -t / 2))
                dashed.move(to: CGPoint(x: 0, y: t / 2)); dashed.addLine(to: CGPoint(x: len, y: t / 2))
                l.stroke(dashed, with: .color(stroke.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            var posts = Path()
            posts.move(to: CGPoint(x: 0, y: -t / 2)); posts.addLine(to: CGPoint(x: 0, y: t / 2))
            posts.move(to: CGPoint(x: len, y: -t / 2)); posts.addLine(to: CGPoint(x: len, y: t / 2))
            l.stroke(posts, with: .color(stroke), lineWidth: 2)
            if selected {
                l.stroke(Path(roundedRect: CGRect(x: -3, y: -t / 2 - 5, width: len + 6, height: t + 10), cornerRadius: 3), with: .color(dim), lineWidth: 1.5)
            }
        }
    }

    private func drawOpeningDims(_ ctx: inout GraphicsContext, _ o: PlanOpening, emphasized: Bool) {
        let i = o.wall
        let n = plan.inwardNormal(i)
        let off = Double((wallPx / 2 + 18) / scale)
        func pt(_ t: Double) -> CGPoint { toScreen(plan.point(onWall: i, at: t) + n * off) }
        func ext(_ t: Double) -> CGPoint { toScreen(plan.point(onWall: i, at: t) + n * Double(wallPx / 2 / scale)) }
        dimensionLine(&ctx, from: pt(o.left), to: pt(o.right), text: Measure.ftIn(o.width), color: emphasized ? dim : .secondary,
                      emphasized: emphasized, extFrom: ext(o.left), extTo: ext(o.right))
        // distance to the nearest wall end on each side (skip if another opening sits in between)
        let others = plan.openings(on: i).filter { $0.id != o.id }
        let leftBlocked = others.contains { $0.right <= o.left + 0.01 }
        let rightBlocked = others.contains { $0.left >= o.right - 0.01 }
        if o.left > 0.03, !leftBlocked {
            dimensionLine(&ctx, from: pt(0), to: pt(o.left), text: Measure.ftIn(o.left), color: .secondary, emphasized: false, extFrom: nil, extTo: nil)
        }
        let rightGap = plan.wallLength(i) - o.right
        if rightGap > 0.03, !rightBlocked {
            dimensionLine(&ctx, from: pt(o.right), to: pt(plan.wallLength(i)), text: Measure.ftIn(rightGap), color: .secondary, emphasized: false, extFrom: nil, extTo: nil)
        }
        // gaps between neighbouring openings
        if let next = others.filter({ $0.left >= o.right - 0.01 }).min(by: { $0.left < $1.left }), next.left - o.right > 0.03 {
            dimensionLine(&ctx, from: pt(o.right), to: pt(next.left), text: Measure.ftIn(next.left - o.right), color: .secondary, emphasized: false, extFrom: nil, extTo: nil)
        }
    }

    private func drawObject(_ ctx: inout GraphicsContext, _ o: PlanObject) {
        let c = toScreen(o.center)
        let w = o.width * scale, h = o.depth * scale
        let sel = selection == .object(o.id)
        ctx.drawLayer { l in
            l.translateBy(x: c.x, y: c.y)
            l.rotate(by: .radians(o.rotation))
            let r = Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: 2)
            l.fill(r, with: .color(sel ? dim.opacity(0.15) : ink.opacity(0.06)))
            l.stroke(r, with: .color(sel ? dim : ink.opacity(0.55)), lineWidth: sel ? 2 : 1)
            if w > 34 && h > 22 {
                // keep text upright
                var a = o.rotation.truncatingRemainder(dividingBy: 2 * .pi)
                if a > .pi { a -= 2 * .pi } else if a < -.pi { a += 2 * .pi }
                let flip = a > .pi / 2 || a < -.pi / 2
                l.drawLayer { t in
                    if flip { t.rotate(by: .radians(.pi)) }
                    t.draw(Text(o.category.capitalized).font(.system(size: 9, weight: .semibold)).foregroundStyle(sel ? dim : .secondary),
                           at: CGPoint(x: 0, y: -6), anchor: .center)
                    t.draw(Text("\(Measure.ftIn(o.width)) × \(Measure.ftIn(o.depth))").font(.system(size: 8)).foregroundStyle(.secondary),
                           at: CGPoint(x: 0, y: 6), anchor: .center)
                }
            }
        }
    }

    /// Dimension line with end ticks, label in the middle (rotated along the line), optional extension lines to the measured edge.
    private func dimensionLine(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint, text: String, color: Color, emphasized: Bool,
                               extFrom: CGPoint?, extTo: CGPoint?) {
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 1 else { return }
        let angle = atan2(b.y - a.y, b.x - a.x)
        if let extFrom, let extTo {
            var ext = Path()
            ext.move(to: extFrom); ext.addLine(to: a)
            ext.move(to: extTo); ext.addLine(to: b)
            ctx.stroke(ext, with: .color(color.opacity(0.5)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
        }
        ctx.drawLayer { l in
            l.translateBy(x: a.x, y: a.y)
            l.rotate(by: .radians(angle))
            var p = Path()
            p.move(to: .zero); p.addLine(to: CGPoint(x: len, y: 0))
            p.move(to: CGPoint(x: 0, y: -5)); p.addLine(to: CGPoint(x: 0, y: 5))
            p.move(to: CGPoint(x: len, y: -5)); p.addLine(to: CGPoint(x: len, y: 5))
            l.stroke(p, with: .color(color.opacity(0.8)), lineWidth: emphasized ? 1.2 : 0.8)
        }
        var a2 = angle
        if a2 > .pi / 2 { a2 -= .pi } else if a2 < -.pi / 2 { a2 += .pi }
        let labelColor: Color = emphasized ? dim : (color == .secondary ? dim.opacity(0.9) : color)
        let resolved = ctx.resolve(Text(text).font(emphasized ? .caption.bold() : .caption2.weight(.medium)).foregroundStyle(labelColor))
        let size = resolved.measure(in: CGSize(width: 200, height: 40))
        ctx.drawLayer { l in
            l.translateBy(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            l.rotate(by: .radians(a2))
            let bg = CGRect(x: -size.width / 2 - 4, y: -size.height / 2 - 1, width: size.width + 8, height: size.height + 2)
            l.fill(Path(roundedRect: bg, cornerRadius: 4), with: .color(Color(.systemGroupedBackground)))
            l.draw(resolved, at: .zero, anchor: .center)
        }
    }
}
