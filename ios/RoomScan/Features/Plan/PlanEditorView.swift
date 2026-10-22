import SwiftUI

enum PlanSelection: Hashable {
    case wall(Int)
    case corner(Int)
    case opening(UUID)
}

/// Top-down editable floor plan: pan/zoom, drag corners, drag openings along walls,
/// tap to select walls/openings, dimension labels on every wall.
struct PlanEditorView: View {
    @Binding var plan: FloorPlan
    @Binding var selection: PlanSelection?
    var onBeginEdit: () -> Void
    var onEndEdit: () -> Void

    @State private var scale: CGFloat = 60          // points per meter
    @State private var baseScale: CGFloat = 60
    @State private var origin: CGPoint = .zero      // screen position of plan (0,0)
    @State private var didFit = false
    @State private var drag: DragTarget?

    private enum DragTarget { case corner(Int), opening(UUID), pan(CGPoint) }

    private let wallColor = Color(.label)
    private let dimColor = Color.blue

    var body: some View {
        GeometryReader { geo in
            Canvas(rendersAsynchronously: false) { ctx, size in
                draw(&ctx, size: size)
            }
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
            .overlay(alignment: .bottomTrailing) {
                Button { fit(in: geo.size) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").padding(8)
                        .background(.regularMaterial, in: Circle())
                }
                .padding(10)
            }
        }
    }

    // MARK: Transform

    private func toScreen(_ p: PlanPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
    private func toPlan(_ s: CGPoint) -> PlanPoint { PlanPoint(x: (s.x - origin.x) / scale, y: (s.y - origin.y) / scale) }

    private func fit(in size: CGSize) {
        let b = plan.bounds
        let w = max(b.max.x - b.min.x, 0.5), h = max(b.max.y - b.min.y, 0.5)
        scale = min((size.width - 120) / w, (size.height - 140) / h)
        scale = min(max(scale, 15), 400)
        baseScale = scale
        let center = PlanPoint(x: (b.min.x + b.max.x) / 2, y: (b.min.y + b.max.y) / 2)
        origin = CGPoint(x: size.width / 2 - center.x * scale, y: size.height / 2 - center.y * scale)
    }

    private var wallPx: CGFloat { max(plan.wallThickness * scale, 6) }

    // MARK: Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { v in
                if drag == nil {
                    switch hitTest(v.startLocation) {
                    case .corner(let i): drag = .corner(i); onBeginEdit()
                    case .opening(let id): drag = .opening(id); onBeginEdit()
                    default: drag = .pan(origin)
                    }
                }
                switch drag! {
                case .corner(let i):
                    plan.moveCorner(i, to: snap(toPlan(v.location)))
                case .opening(let id):
                    guard let k = plan.openings.firstIndex(where: { $0.id == id }) else { return }
                    let o = plan.openings[k]
                    let p = toPlan(v.location)
                    let t = (p - plan.wallStart(o.wall)).dot(plan.wallDirection(o.wall))
                    let half = o.width / 2
                    plan.openings[k].offset = snap(min(max(t, half), max(half, plan.wallLength(o.wall) - half)))
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
        for o in plan.openings {
            let (a, b) = openingSegment(o)
            if distance(s, toScreen(a), toScreen(b)) < max(wallPx, 16) { return .opening(o.id) }
        }
        for i in 0..<plan.wallCount where hypot(toScreen(plan.corners[i]).x - s.x, toScreen(plan.corners[i]).y - s.y) < 18 {
            return .corner(i)
        }
        for i in 0..<plan.wallCount {
            if distance(s, toScreen(plan.wallStart(i)), toScreen(plan.wallEnd(i))) < max(wallPx, 14) { return .wall(i) }
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
        drawGrid(&ctx, size: size)
        guard plan.wallCount >= 3 else { return }

        // Floor
        var floor = Path()
        floor.move(to: toScreen(plan.corners[0]))
        for c in plan.corners.dropFirst() { floor.addLine(to: toScreen(c)) }
        floor.closeSubpath()
        ctx.fill(floor, with: .color(Color(.systemBackground)))
        drawFloorGrid(&ctx, clip: floor)

        // Objects (under walls)
        for o in plan.objects { drawObject(&ctx, o) }

        // Walls
        for i in 0..<plan.wallCount {
            var p = Path()
            p.move(to: toScreen(plan.wallStart(i))); p.addLine(to: toScreen(plan.wallEnd(i)))
            let selected = selection == .wall(i)
            ctx.stroke(p, with: .color(selected ? .accentColor : wallColor), style: StrokeStyle(lineWidth: wallPx, lineCap: .square))
        }

        // Openings
        for o in plan.openings { drawOpening(&ctx, o) }

        // Corners
        for i in 0..<plan.wallCount {
            let c = toScreen(plan.corners[i])
            let r: CGFloat = selection == .corner(i) ? 9 : 6
            let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.fill(circle, with: .color(selection == .corner(i) ? .accentColor : .white))
            ctx.stroke(circle, with: .color(wallColor), lineWidth: 1.5)
        }

        // Wall dimensions
        for i in 0..<plan.wallCount {
            let mid = plan.wallMid(i)
            let n = plan.outwardNormal(i)
            let pos = toScreen(mid + n * Double((wallPx / 2 + 18) / scale))
            let d = plan.wallDirection(i)
            drawLabel(&ctx, Measure.ftIn(plan.wallLength(i)), at: pos, angle: atan2(d.y, d.x),
                      color: selection == .wall(i) ? .accentColor : dimColor, emphasized: selection == .wall(i))
        }

        // Overall size
        let b = plan.bounds
        let top = CGPoint(x: toScreen(PlanPoint(x: (b.min.x + b.max.x) / 2, y: b.min.y)).x, y: toScreen(b.min).y - wallPx / 2 - 46)
        drawLabel(&ctx, "↔ \(Measure.ftIn(plan.width))", at: top, angle: 0, color: .secondary, emphasized: false)
        let left = CGPoint(x: toScreen(b.min).x - wallPx / 2 - 46, y: toScreen(PlanPoint(x: b.min.x, y: (b.min.y + b.max.y) / 2)).y)
        drawLabel(&ctx, "↕ \(Measure.ftIn(plan.depth))", at: left, angle: -.pi / 2, color: .secondary, emphasized: false)

        // Opening distances for selected wall
        if case .wall(let i) = selection {
            for o in plan.openings(on: i) { drawOpeningDims(&ctx, o) }
        } else if case .opening(let id) = selection, let o = plan.openings.first(where: { $0.id == id }) {
            drawOpeningDims(&ctx, o)
        }
    }

    private func drawGrid(_ ctx: inout GraphicsContext, size: CGSize) {
        let step = scale * 0.3048   // 1 ft
        guard step > 8 else { return }
        var dots = Path()
        var x = origin.x.truncatingRemainder(dividingBy: step); if x < 0 { x += step }
        var y0 = origin.y.truncatingRemainder(dividingBy: step); if y0 < 0 { y0 += step }
        while x < size.width {
            var y = y0
            while y < size.height { dots.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)); y += step }
            x += step
        }
        ctx.fill(dots, with: .color(.secondary.opacity(0.35)))
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
        g.stroke(lines, with: .color(.orange.opacity(0.18)), lineWidth: 0.5)
    }

    private func drawOpening(_ ctx: inout GraphicsContext, _ o: PlanOpening) {
        let (a, b) = openingSegment(o)
        let sa = toScreen(a), sb = toScreen(b)
        let len = hypot(sb.x - sa.x, sb.y - sa.y)
        let angle = atan2(sb.y - sa.y, sb.x - sa.x)
        let inwardSign: CGFloat = plan.inwardNormal(o.wall).dot(plan.wallDirection(o.wall).perp) > 0 ? 1 : -1
        let selected = selection == .opening(o.id)
        let t = wallPx

        ctx.drawLayer { l in
            l.translateBy(x: sa.x, y: sa.y)
            l.rotate(by: .radians(angle))
            // gap in the wall
            l.fill(Path(CGRect(x: 0, y: -t / 2 - 0.5, width: len, height: t + 1)), with: .color(Color(.systemBackground)))
            switch o.kind {
            case .door:
                var leaf = Path()
                leaf.move(to: .zero); leaf.addLine(to: CGPoint(x: 0, y: inwardSign * len))
                var arc = Path()
                arc.move(to: CGPoint(x: len, y: 0))
                for k in 1...12 {
                    let a = Double(k) / 12 * .pi / 2
                    arc.addLine(to: CGPoint(x: len * cos(a), y: inwardSign * len * sin(a)))
                }
                l.stroke(leaf, with: .color(selected ? .accentColor : wallColor), lineWidth: 2)
                l.stroke(arc, with: .color(selected ? .accentColor : .secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            case .window:
                l.fill(Path(CGRect(x: 0, y: -t / 4, width: len, height: t / 2)), with: .color(.cyan.opacity(0.25)))
                var lines = Path()
                lines.move(to: CGPoint(x: 0, y: -t / 4)); lines.addLine(to: CGPoint(x: len, y: -t / 4))
                lines.move(to: CGPoint(x: 0, y: t / 4)); lines.addLine(to: CGPoint(x: len, y: t / 4))
                l.stroke(lines, with: .color(selected ? .accentColor : wallColor), lineWidth: 1.5)
            case .opening:
                var dashed = Path()
                dashed.move(to: CGPoint(x: 0, y: 0)); dashed.addLine(to: CGPoint(x: len, y: 0))
                l.stroke(dashed, with: .color(selected ? .accentColor : .secondary), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            // end posts
            var posts = Path()
            posts.move(to: CGPoint(x: 0, y: -t / 2)); posts.addLine(to: CGPoint(x: 0, y: t / 2))
            posts.move(to: CGPoint(x: len, y: -t / 2)); posts.addLine(to: CGPoint(x: len, y: t / 2))
            l.stroke(posts, with: .color(selected ? .accentColor : wallColor), lineWidth: 2)
            if selected {
                l.stroke(Path(CGRect(x: -2, y: -t / 2 - 3, width: len + 4, height: t + 6)), with: .color(.accentColor), lineWidth: 1.5)
            }
        }
    }

    private func drawOpeningDims(_ ctx: inout GraphicsContext, _ o: PlanOpening) {
        let i = o.wall
        let n = plan.inwardNormal(i)
        let d = plan.wallDirection(i)
        let off = Double((wallPx / 2 + 16) / scale)
        let angle = atan2(d.y, d.x)
        // width label inside the room, under the opening
        drawLabel(&ctx, Measure.ftIn(o.width), at: toScreen(plan.point(onWall: i, at: o.offset) + n * off), angle: angle, color: .accentColor, emphasized: true)
        // distance from wall start to opening
        if o.left > 0.02 {
            drawLabel(&ctx, Measure.ftIn(o.left), at: toScreen(plan.point(onWall: i, at: o.left / 2) + n * (off + 0.0)), angle: angle, color: .secondary, emphasized: false)
        }
        let rightGap = plan.wallLength(i) - o.right
        if rightGap > 0.02 {
            drawLabel(&ctx, Measure.ftIn(rightGap), at: toScreen(plan.point(onWall: i, at: o.right + rightGap / 2) + n * off), angle: angle, color: .secondary, emphasized: false)
        }
    }

    private func drawObject(_ ctx: inout GraphicsContext, _ o: PlanObject) {
        let c = toScreen(o.center)
        let w = o.width * scale, h = o.depth * scale
        ctx.drawLayer { l in
            l.translateBy(x: c.x, y: c.y)
            l.rotate(by: .radians(o.rotation))
            let r = Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: 3)
            l.fill(r, with: .color(.secondary.opacity(0.12)))
            l.stroke(r, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
            if w > 30 && h > 16 {
                l.draw(Text(o.category.capitalized).font(.system(size: 9)).foregroundStyle(.secondary), at: .zero, anchor: .center)
            }
        }
    }

    private func drawLabel(_ ctx: inout GraphicsContext, _ text: String, at p: CGPoint, angle: Double, color: Color, emphasized: Bool) {
        var a = angle
        if a > .pi / 2 { a -= .pi } else if a < -.pi / 2 { a += .pi }
        let resolved = ctx.resolve(Text(text).font(emphasized ? .caption.bold() : .caption).foregroundStyle(color))
        let size = resolved.measure(in: CGSize(width: 200, height: 40))
        ctx.drawLayer { l in
            l.translateBy(x: p.x, y: p.y)
            l.rotate(by: .radians(a))
            let bg = CGRect(x: -size.width / 2 - 4, y: -size.height / 2 - 1, width: size.width + 8, height: size.height + 2)
            l.fill(Path(roundedRect: bg, cornerRadius: 4), with: .color(Color(.systemGroupedBackground).opacity(0.9)))
            l.draw(resolved, at: .zero, anchor: .center)
        }
    }
}
