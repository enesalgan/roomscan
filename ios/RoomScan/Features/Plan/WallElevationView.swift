import SwiftUI

/// Elevation of one wall: height, length, and every opening with its width / height / sill
/// and distance from the wall ends. Drag an opening sideways to move it. ◀ ▶ switch walls.
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
                .overlay(alignment: .leading) { arrow("arrow.left") { step(-1) } }
                .overlay(alignment: .trailing) { arrow("arrow.right") { step(1) } }
        }
    }

    private func step(_ d: Int) {
        wall = (wall + d + plan.wallCount) % plan.wallCount
        selection = .wall(wall)
    }

    private func arrow(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.title2).padding(14)
                .background(.regularMaterial, in: Circle())
        }
        .padding(8)
    }

    // MARK: Transform (wall x → screen x, height → screen y up)

    private struct T { var scale: CGFloat; var originX: CGFloat; var floorY: CGFloat }

    private func transform(for size: CGSize) -> T {
        let L = max(plan.wallLength(wall), 0.5), H = max(plan.wallHeight, 1)
        let scale = min((size.width - 150) / L, (size.height - 150) / H)
        let originX = (size.width - L * scale) / 2
        let floorY = size.height / 2 + H * scale / 2
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

        // side walls (perspective hint)
        let depth: CGFloat = 22
        var sides = Path()
        sides.move(to: CGPoint(x: wallRect.minX, y: wallRect.minY)); sides.addLine(to: CGPoint(x: wallRect.minX - depth, y: wallRect.minY - depth))
        sides.addLine(to: CGPoint(x: wallRect.minX - depth, y: wallRect.maxY + depth)); sides.addLine(to: CGPoint(x: wallRect.minX, y: wallRect.maxY)); sides.closeSubpath()
        sides.move(to: CGPoint(x: wallRect.maxX, y: wallRect.minY)); sides.addLine(to: CGPoint(x: wallRect.maxX + depth, y: wallRect.minY - depth))
        sides.addLine(to: CGPoint(x: wallRect.maxX + depth, y: wallRect.maxY + depth)); sides.addLine(to: CGPoint(x: wallRect.maxX, y: wallRect.maxY)); sides.closeSubpath()
        ctx.fill(sides, with: .color(.secondary.opacity(0.25)))
        ctx.stroke(sides, with: .color(Color(.label)), lineWidth: 1)

        ctx.fill(Path(wallRect), with: .color(Color(.systemBackground)))
        ctx.stroke(Path(wallRect), with: .color(Color(.label)), lineWidth: 2)

        // openings
        for o in plan.openings(on: wall) {
            let r = rect(o, t)
            let selected = selection == .opening(o.id)
            switch o.kind {
            case .door:
                ctx.fill(Path(r), with: .color(.brown.opacity(0.15)))
                ctx.stroke(Path(r.insetBy(dx: 6, dy: 6)), with: .color(.secondary), lineWidth: 1)
            case .window:
                ctx.fill(Path(r), with: .color(.cyan.opacity(0.2)))
                var cross = Path()
                cross.move(to: CGPoint(x: r.midX, y: r.minY)); cross.addLine(to: CGPoint(x: r.midX, y: r.maxY))
                ctx.stroke(cross, with: .color(.secondary), lineWidth: 1)
            case .opening:
                ctx.fill(Path(r), with: .color(.secondary.opacity(0.08)))
            }
            ctx.stroke(Path(r), with: .color(selected ? .accentColor : Color(.label)), lineWidth: selected ? 3 : 1.5)

            // labels: width under, height at right, sill
            label(&ctx, Measure.ftIn(o.width), at: CGPoint(x: r.midX, y: r.maxY + 12), color: selected ? .accentColor : .blue)
            label(&ctx, Measure.ftIn(o.height), at: CGPoint(x: r.maxX + 22, y: r.midY), color: .blue, angle: -.pi / 2)
            if o.sill > 0.02 {
                dimLine(&ctx, from: CGPoint(x: r.midX, y: r.maxY), to: CGPoint(x: r.midX, y: t.floorY), text: Measure.ftIn(o.sill))
            }
            if selected {
                // distances to wall ends
                if o.left > 0.02 {
                    dimLine(&ctx, from: CGPoint(x: wallRect.minX, y: r.minY - 14), to: CGPoint(x: r.minX, y: r.minY - 14), text: Measure.ftIn(o.left))
                }
                let right = L - o.right
                if right > 0.02 {
                    dimLine(&ctx, from: CGPoint(x: r.maxX, y: r.minY - 14), to: CGPoint(x: wallRect.maxX, y: r.minY - 14), text: Measure.ftIn(right))
                }
            }
        }

        // wall dims
        dimLine(&ctx, from: CGPoint(x: wallRect.minX, y: wallRect.maxY + 34), to: CGPoint(x: wallRect.maxX, y: wallRect.maxY + 34), text: Measure.ftIn(L))
        dimLine(&ctx, from: CGPoint(x: wallRect.minX - depth - 26, y: wallRect.maxY), to: CGPoint(x: wallRect.minX - depth - 26, y: wallRect.minY), text: Measure.ftIn(H))
    }

    private func dimLine(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint, text: String) {
        var p = Path()
        p.move(to: a); p.addLine(to: b)
        let vertical = abs(a.x - b.x) < 1
        let tick: CGFloat = 5
        if vertical {
            p.move(to: CGPoint(x: a.x - tick, y: a.y)); p.addLine(to: CGPoint(x: a.x + tick, y: a.y))
            p.move(to: CGPoint(x: b.x - tick, y: b.y)); p.addLine(to: CGPoint(x: b.x + tick, y: b.y))
        } else {
            p.move(to: CGPoint(x: a.x, y: a.y - tick)); p.addLine(to: CGPoint(x: a.x, y: a.y + tick))
            p.move(to: CGPoint(x: b.x, y: b.y - tick)); p.addLine(to: CGPoint(x: b.x, y: b.y + tick))
        }
        ctx.stroke(p, with: .color(.secondary), lineWidth: 1)
        label(&ctx, text, at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), color: .blue, angle: vertical ? -.pi / 2 : 0)
    }

    private func label(_ ctx: inout GraphicsContext, _ text: String, at p: CGPoint, color: Color, angle: Double = 0) {
        let resolved = ctx.resolve(Text(text).font(.caption.bold()).foregroundStyle(color))
        let size = resolved.measure(in: CGSize(width: 200, height: 40))
        ctx.drawLayer { l in
            l.translateBy(x: p.x, y: p.y)
            l.rotate(by: .radians(angle))
            l.fill(Path(roundedRect: CGRect(x: -size.width / 2 - 4, y: -size.height / 2 - 1, width: size.width + 8, height: size.height + 2), cornerRadius: 4),
                   with: .color(Color(.systemGroupedBackground).opacity(0.92)))
            l.draw(resolved, at: .zero, anchor: .center)
        }
    }
}
