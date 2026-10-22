import SwiftUI

/// Elevation of one wall: length, height, and every opening with width / height / sill / head
/// and distances to the wall ends — all as proper dimension lines. Drag an opening sideways to move it.
struct WallElevationView: View {
    @Binding var plan: FloorPlan
    @Binding var wall: Int
    @Binding var selection: PlanSelection?
    var onBeginEdit: () -> Void
    var onEndEdit: () -> Void

    @State private var dragging: UUID?

    var body: some View {
        GeometryReader { geo in
            let t = transform(for: geo.size)
            Canvas { ctx, size in draw(&ctx, t: t) }
                .background(Color(.systemGroupedBackground))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { v in
                            if dragging == nil {
                                guard let id = hit(v.startLocation, t: t) else { return }
                                dragging = id; selection = .opening(id); onBeginEdit()
                            }
                            guard let id = dragging, let k = plan.openings.firstIndex(where: { $0.id == id }) else { return }
                            let x = Double((v.location.x - t.originX) / t.scale)
                            let half = plan.openings[k].width / 2
                            let len = plan.wallLength(wall)
                            plan.openings[k].offset = ((min(max(x, half), max(half, len - half))) / 0.00635).rounded() * 0.00635
                        }
                        .onEnded { _ in if dragging != nil { onEndEdit() }; dragging = nil }
                )
                .onTapGesture { loc in
                    if let id = hit(loc, t: t) { selection = PlanSelection.opening(id) } else { selection = PlanSelection.wall(wall) }
                }
                .overlay(alignment: .top) {
                    Text("Wall \(wall + 1) of \(plan.wallCount)")
                        .font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule()).padding(.top, 8)
                }
                .overlay(alignment: .leading) { arrow("chevron.left") { step(-1) } }
                .overlay(alignment: .trailing) { arrow("chevron.right") { step(1) } }
        }
    }

    private func step(_ d: Int) {
        wall = (wall + d + plan.wallCount) % plan.wallCount
        selection = .wall(wall)
    }

    private func arrow(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
        }
        .padding(6)
    }

    // MARK: Transform (wall x → screen x, height → screen y up)

    private struct T { var scale: CGFloat; var originX: CGFloat; var floorY: CGFloat }

    private func transform(for size: CGSize) -> T {
        let L = max(plan.wallLength(wall), 0.5), H = max(plan.wallHeight, 1)
        let scale = min((size.width - 170) / L, (size.height - 190) / H)
        let originX = (size.width - L * scale) / 2
        let floorY = size.height / 2 + H * scale / 2 - 10
        return T(scale: scale, originX: originX, floorY: floorY)
    }

    private func rect(_ o: PlanOpening, _ t: T) -> CGRect {
        CGRect(x: t.originX + o.left * t.scale, y: t.floorY - (o.sill + o.height) * t.scale,
               width: o.width * t.scale, height: o.height * t.scale)
    }

    private func hit(_ p: CGPoint, t: T) -> UUID? {
        plan.openings(on: wall).first { rect($0, t).insetBy(dx: -8, dy: -8).contains(p) }?.id
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, t: T) {
        let L = plan.wallLength(wall), H = plan.wallHeight
        let wallRect = CGRect(x: t.originX, y: t.floorY - H * t.scale, width: L * t.scale, height: H * t.scale)
        let ink = Color(.label)
        let depth: CGFloat = 20

        // side returns (perspective hint)
        var sides = Path()
        sides.move(to: CGPoint(x: wallRect.minX, y: wallRect.minY)); sides.addLine(to: CGPoint(x: wallRect.minX - depth, y: wallRect.minY - depth))
        sides.addLine(to: CGPoint(x: wallRect.minX - depth, y: wallRect.maxY + depth)); sides.addLine(to: CGPoint(x: wallRect.minX, y: wallRect.maxY)); sides.closeSubpath()
        sides.move(to: CGPoint(x: wallRect.maxX, y: wallRect.minY)); sides.addLine(to: CGPoint(x: wallRect.maxX + depth, y: wallRect.minY - depth))
        sides.addLine(to: CGPoint(x: wallRect.maxX + depth, y: wallRect.maxY + depth)); sides.addLine(to: CGPoint(x: wallRect.maxX, y: wallRect.maxY)); sides.closeSubpath()
        ctx.fill(sides, with: .color(ink.opacity(0.12)))
        ctx.stroke(sides, with: .color(ink.opacity(0.6)), lineWidth: 1)

        ctx.fill(Path(wallRect), with: .color(Color(.systemBackground)))
        ctx.stroke(Path(wallRect), with: .color(ink), lineWidth: 2)

        let openings = plan.openings(on: wall)
        for o in openings {
            let r = rect(o, t)
            let selected = selection == .opening(o.id)
            let stroke = selected ? Color.accentColor : ink
            switch o.kind {
            case .door:
                ctx.fill(Path(r), with: .color(.brown.opacity(0.12)))
                ctx.stroke(Path(r.insetBy(dx: 7, dy: 7)), with: .color(ink.opacity(0.4)), lineWidth: 1)
            case .window:
                ctx.fill(Path(r), with: .color(.cyan.opacity(0.18)))
                var cross = Path()
                cross.move(to: CGPoint(x: r.midX, y: r.minY)); cross.addLine(to: CGPoint(x: r.midX, y: r.maxY))
                cross.move(to: CGPoint(x: r.minX, y: r.midY)); cross.addLine(to: CGPoint(x: r.maxX, y: r.midY))
                ctx.stroke(cross, with: .color(ink.opacity(0.4)), lineWidth: 1)
            case .opening:
                ctx.fill(Path(r), with: .color(ink.opacity(0.05)))
            }
            ctx.stroke(Path(r), with: .color(stroke), lineWidth: selected ? 3 : 1.5)

            // width (below opening, inside)
            dimensionLine(&ctx, from: CGPoint(x: r.minX, y: r.maxY + 14), to: CGPoint(x: r.maxX, y: r.maxY + 14), text: Measure.ftIn(o.width), emphasized: selected)
            // height (right of opening)
            dimensionLine(&ctx, from: CGPoint(x: r.maxX + 16, y: r.maxY), to: CGPoint(x: r.maxX + 16, y: r.minY), text: Measure.ftIn(o.height), emphasized: selected)
            // sill (bottom → floor) and head gap (top → ceiling)
            if o.sill > 0.02 {
                dimensionLine(&ctx, from: CGPoint(x: r.minX - 16, y: wallRect.maxY), to: CGPoint(x: r.minX - 16, y: r.maxY), text: Measure.ftIn(o.sill), emphasized: false)
            }
            let head = H - o.sill - o.height
            if head > 0.02 {
                dimensionLine(&ctx, from: CGPoint(x: r.minX - 16, y: r.minY), to: CGPoint(x: r.minX - 16, y: wallRect.minY), text: Measure.ftIn(head), emphasized: false)
            }
        }

        // distances between wall ends and openings (chain along the top)
        if !openings.isEmpty {
            let y = wallRect.minY - 18
            var cursorX = wallRect.minX, cursorT = 0.0
            for o in openings {
                let r = rect(o, t)
                if o.left - cursorT > 0.03 {
                    dimensionLine(&ctx, from: CGPoint(x: cursorX, y: y), to: CGPoint(x: r.minX, y: y), text: Measure.ftIn(o.left - cursorT), emphasized: false)
                }
                cursorX = r.maxX; cursorT = o.right
            }
            if L - cursorT > 0.03 {
                dimensionLine(&ctx, from: CGPoint(x: cursorX, y: y), to: CGPoint(x: wallRect.maxX, y: y), text: Measure.ftIn(L - cursorT), emphasized: false)
            }
        }

        // overall: length (bottom), height (left, outside the return)
        dimensionLine(&ctx, from: CGPoint(x: wallRect.minX, y: wallRect.maxY + depth + 30), to: CGPoint(x: wallRect.maxX, y: wallRect.maxY + depth + 30), text: Measure.ftIn(L), emphasized: true)
        dimensionLine(&ctx, from: CGPoint(x: wallRect.minX - depth - 34, y: wallRect.maxY), to: CGPoint(x: wallRect.minX - depth - 34, y: wallRect.minY), text: Measure.ftIn(H), emphasized: true)
    }

    private func dimensionLine(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint, text: String, emphasized: Bool) {
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 1 else { return }
        let angle = atan2(b.y - a.y, b.x - a.x)
        let color: Color = emphasized ? .accentColor : Color(.label).opacity(0.75)
        ctx.drawLayer { l in
            l.translateBy(x: a.x, y: a.y)
            l.rotate(by: .radians(angle))
            var p = Path()
            p.move(to: .zero); p.addLine(to: CGPoint(x: len, y: 0))
            p.move(to: CGPoint(x: 0, y: -5)); p.addLine(to: CGPoint(x: 0, y: 5))
            p.move(to: CGPoint(x: len, y: -5)); p.addLine(to: CGPoint(x: len, y: 5))
            l.stroke(p, with: .color(color), lineWidth: emphasized ? 1.5 : 1)
        }
        var a2 = angle
        if a2 > .pi / 2 { a2 -= .pi } else if a2 < -.pi / 2 { a2 += .pi }
        let resolved = ctx.resolve(Text(text).font(emphasized ? .caption.bold() : .caption2.bold()).foregroundStyle(color))
        let size = resolved.measure(in: CGSize(width: 200, height: 40))
        ctx.drawLayer { l in
            l.translateBy(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            l.rotate(by: .radians(a2))
            l.fill(Path(roundedRect: CGRect(x: -size.width / 2 - 4, y: -size.height / 2 - 1, width: size.width + 8, height: size.height + 2), cornerRadius: 4),
                   with: .color(Color(.systemGroupedBackground)))
            l.draw(resolved, at: .zero, anchor: .center)
        }
    }
}
