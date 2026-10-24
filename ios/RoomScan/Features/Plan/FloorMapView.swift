import SwiftUI

/// All scanned rooms of a job on one floor plan. Drag a room to place it, rotate in 90° steps,
/// pinch/pan the canvas. Placements are saved on the job (floor_layout).
struct FloorMapView: View {
    @Environment(\.dismiss) private var dismiss
    @State var job: Job
    let scans: [Scan]
    var onSaved: (Job) -> Void = { _ in }

    @State private var placements: [RoomPlacement] = []
    @State private var selected: UUID?
    @State private var scale: CGFloat = 40
    @State private var baseScale: CGFloat = 40
    @State private var origin: CGPoint = .zero
    @State private var pinchOrigin: CGPoint?
    @State private var dragStart: PlanPoint?
    @State private var didFit = false
    @State private var dirty = false
    @State private var saving = false
    @State private var error: String?

    private var rooms: [Scan] { scans.filter { $0.plan != nil } }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                FloorMapCanvas(rooms: rooms, placements: placements, selected: selected, scale: scale, origin: origin, interactive: true)
                    .contentShape(Rectangle())
                    .gesture(dragGesture)
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { v in
                                if pinchOrigin == nil { pinchOrigin = origin }
                                let newScale = min(max(baseScale * v.magnification, 8), 300)
                                let k = newScale / baseScale, o = pinchOrigin ?? origin, a = v.startLocation
                                origin = CGPoint(x: a.x - (a.x - o.x) * k, y: a.y - (a.y - o.y) * k)
                                scale = newScale
                            }
                            .onEnded { _ in baseScale = scale; pinchOrigin = nil }
                    )
                    .onTapGesture { loc in selected = hit(loc) }
                    .onAppear { setup(); if geo.size.width > 0, !didFit { fit(in: geo.size); didFit = true } }
                    .onChange(of: geo.size) { _, size in if size.width > 0, !didFit { fit(in: size); didFit = true } }
                    .overlay(alignment: .bottomTrailing) {
                        Button { withAnimation { fit(in: geo.size) } } label: {
                            Image(systemName: "arrow.down.left.and.arrow.up.right").font(.body.weight(.semibold)).padding(10)
                                .background(.regularMaterial, in: Circle())
                        }
                        .padding(12)
                    }
                    .overlay(alignment: .bottom) { bottomBar }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Floor plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(dirty ? "Discard" : "Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: { if saving { ProgressView() } else { Text("Save").bold() } }
                        .disabled(!dirty || saving)
                }
            }
            .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
        }
    }

    // MARK: Setup / layout

    private func setup() {
        var out: [RoomPlacement] = []
        var cursorX = 0.0
        for r in rooms {
            if let p = job.floorLayout?.first(where: { $0.scanId == r.id }) {
                out.append(p)
            } else {
                out.append(RoomPlacement(scanId: r.id, x: cursorX, y: 0, rotation: 0))
            }
            cursorX += (r.plan?.width ?? 3) + 0.6
        }
        placements = out
    }

    private func fit(in size: CGSize) {
        var mn = PlanPoint(x: .infinity, y: .infinity), mx = PlanPoint(x: -.infinity, y: -.infinity)
        for r in rooms {
            guard let plan = r.plan, let pl = placement(for: r.id) else { continue }
            for c in plan.corners.map({ transform($0, pl) }) {
                mn.x = min(mn.x, c.x); mn.y = min(mn.y, c.y); mx.x = max(mx.x, c.x); mx.y = max(mx.y, c.y)
            }
        }
        guard mn.x.isFinite else { return }
        let w = max(mx.x - mn.x, 1), h = max(mx.y - mn.y, 1)
        scale = min(max(min((size.width - 80) / w, (size.height - 200) / h), 8), 300)
        baseScale = scale
        origin = CGPoint(x: size.width / 2 - (mn.x + mx.x) / 2 * scale, y: size.height / 2 - 30 - (mn.y + mx.y) / 2 * scale)
    }

    private func placement(for id: UUID) -> RoomPlacement? { placements.first { $0.scanId == id } }

    static func transform(_ p: PlanPoint, _ pl: RoomPlacement) -> PlanPoint {
        PlanPoint(x: p.x * cos(pl.rotation) - p.y * sin(pl.rotation) + pl.x, y: p.x * sin(pl.rotation) + p.y * cos(pl.rotation) + pl.y)
    }
    private func transform(_ p: PlanPoint, _ pl: RoomPlacement) -> PlanPoint { Self.transform(p, pl) }

    private func toPlan(_ s: CGPoint) -> PlanPoint { PlanPoint(x: (s.x - origin.x) / scale, y: (s.y - origin.y) / scale) }

    private func hit(_ loc: CGPoint) -> UUID? {
        let p = toPlan(loc)
        for r in rooms.reversed() {
            guard let plan = r.plan, let pl = placement(for: r.id) else { continue }
            if Self.contains(plan.corners.map { transform($0, pl) }, p) { return r.id }
        }
        return nil
    }

    static func contains(_ poly: [PlanPoint], _ p: PlanPoint) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            if (poly[i].y > p.y) != (poly[j].y > p.y),
               p.x < (poly[j].x - poly[i].x) * (p.y - poly[i].y) / (poly[j].y - poly[i].y) + poly[i].x { inside.toggle() }
            j = i
        }
        return inside
    }

    // MARK: Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if pinchOrigin != nil { return }
                if dragStart == nil {
                    if let id = hit(v.startLocation), let pl = placement(for: id) {
                        selected = id; dragStart = PlanPoint(x: pl.x, y: pl.y)
                    } else { dragStart = PlanPoint(x: Double(origin.x), y: Double(origin.y)); selected = nil }
                }
                guard let start = dragStart else { return }
                if let id = selected, let k = placements.firstIndex(where: { $0.scanId == id }) {
                    placements[k].x = ((start.x + v.translation.width / scale) / 0.01).rounded() * 0.01
                    placements[k].y = ((start.y + v.translation.height / scale) / 0.01).rounded() * 0.01
                    dirty = true
                } else {
                    origin = CGPoint(x: start.x + v.translation.width, y: start.y + v.translation.height)
                }
            }
            .onEnded { _ in dragStart = nil }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if let id = selected, let r = rooms.first(where: { $0.id == id }) {
                Text(r.name).font(.subheadline.weight(.semibold))
                Spacer()
                Button { rotate(id, by: -.pi / 2) } label: { Image(systemName: "rotate.left") }
                Button { rotate(id, by: .pi / 2) } label: { Image(systemName: "rotate.right") }
                Button("Done") { selected = nil }
            } else {
                Image(systemName: "hand.draw").foregroundStyle(.secondary)
                Text("Tap a room to select, drag to place.").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("\(rooms.count) rooms").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    private func rotate(_ id: UUID, by a: Double) {
        guard let k = placements.firstIndex(where: { $0.scanId == id }), let plan = rooms.first(where: { $0.id == id })?.plan else { return }
        // rotate about the room's centre so it stays in place
        let c = PlanPoint(x: plan.width / 2, y: plan.depth / 2)
        let before = transform(c, placements[k])
        placements[k].rotation += a
        let after = transform(c, placements[k])
        placements[k].x += before.x - after.x; placements[k].y += before.y - after.y
        dirty = true
    }

    private func save() async {
        saving = true; defer { saving = false }
        var j = job
        j.floorLayout = placements
        do { job = try await Repository.upsert(j); onSaved(job); dirty = false }
        catch { self.error = error.localizedDescription }
    }
}

/// Draws rooms on a shared canvas (used by the editor and the small preview on the job page).
struct FloorMapCanvas: View {
    let rooms: [Scan]
    let placements: [RoomPlacement]
    var selected: UUID? = nil
    var scale: CGFloat
    var origin: CGPoint
    var interactive: Bool = true

    var body: some View {
        Canvas { ctx, size in
            // dot grid
            let step = scale * 0.3048
            if step > 8 {
                var dots = Path()
                var x = origin.x.truncatingRemainder(dividingBy: step); if x < 0 { x += step }
                var y0 = origin.y.truncatingRemainder(dividingBy: step); if y0 < 0 { y0 += step }
                while x < size.width { var y = y0; while y < size.height { dots.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)); y += step }; x += step }
                ctx.fill(dots, with: .color(.secondary.opacity(0.35)))
            }
            let ink = Color(.label)
            for r in rooms {
                guard let plan = r.plan, let pl = placements.first(where: { $0.scanId == r.id }) else { continue }
                func sp(_ p: PlanPoint) -> CGPoint { let t = FloorMapView.transform(p, pl); return CGPoint(x: origin.x + t.x * scale, y: origin.y + t.y * scale) }
                let wallPx = max(plan.wallThickness * scale, 3)
                var outline = Path()
                outline.move(to: sp(plan.corners[0])); for c in plan.corners.dropFirst() { outline.addLine(to: sp(c)) }; outline.closeSubpath()
                let sel = selected == r.id
                ctx.fill(outline, with: .color(sel ? Color.accentColor.opacity(0.10) : ink.opacity(0.05)))
                var solid = Path(), dashed = Path()
                for i in 0..<plan.wallCount {
                    let a = sp(plan.wallStart(i)), b = sp(plan.wallEnd(i))
                    if plan.isInferred(i) { dashed.move(to: a); dashed.addLine(to: b) } else { solid.move(to: a); solid.addLine(to: b) }
                }
                ctx.stroke(solid, with: .color(sel ? Color.accentColor : ink), style: StrokeStyle(lineWidth: wallPx, lineCap: .square))
                ctx.stroke(dashed, with: .color(ink.opacity(0.45)), style: StrokeStyle(lineWidth: max(wallPx * 0.45, 1.5), dash: [6, 5]))
                // openings as gaps
                for o in plan.openings {
                    let a = sp(plan.point(onWall: o.wall, at: o.left)), b = sp(plan.point(onWall: o.wall, at: o.right))
                    var gap = Path(); gap.move(to: a); gap.addLine(to: b)
                    ctx.stroke(gap, with: .color(Color(.systemGroupedBackground)), lineWidth: wallPx + 2)
                    if o.kind == .window {
                        ctx.stroke(gap, with: .color(.cyan.opacity(0.8)), lineWidth: max(wallPx * 0.35, 1))
                    }
                }
                // label
                let c = sp(PlanPoint(x: plan.width / 2, y: plan.depth / 2))
                let title = ctx.resolve(Text(r.name).font(.system(size: max(10, min(16, scale * 0.3)), weight: .semibold)).foregroundStyle(ink))
                let sub = ctx.resolve(Text(plan.area.squareFeet).font(.system(size: max(8, min(12, scale * 0.22)))).foregroundStyle(.secondary))
                ctx.draw(title, at: CGPoint(x: c.x, y: c.y - 7), anchor: .center)
                ctx.draw(sub, at: CGPoint(x: c.x, y: c.y + 9), anchor: .center)
            }
        }
    }
}

/// Non-interactive thumbnail of the floor map for the job page
struct FloorMapPreview: View {
    let job: Job
    let scans: [Scan]

    var body: some View {
        GeometryReader { geo in
            let rooms = scans.filter { $0.plan != nil }
            let placements = autoPlacements(rooms)
            let fitted = fit(rooms, placements, geo.size)
            FloorMapCanvas(rooms: rooms, placements: placements, scale: fitted.0, origin: fitted.1, interactive: false)
        }
    }

    private func autoPlacements(_ rooms: [Scan]) -> [RoomPlacement] {
        var out: [RoomPlacement] = []; var x = 0.0
        for r in rooms {
            out.append(job.floorLayout?.first(where: { $0.scanId == r.id }) ?? RoomPlacement(scanId: r.id, x: x, y: 0))
            x += (r.plan?.width ?? 3) + 0.6
        }
        return out
    }

    private func fit(_ rooms: [Scan], _ placements: [RoomPlacement], _ size: CGSize) -> (CGFloat, CGPoint) {
        var mn = PlanPoint(x: .infinity, y: .infinity), mx = PlanPoint(x: -.infinity, y: -.infinity)
        for r in rooms {
            guard let plan = r.plan, let pl = placements.first(where: { $0.scanId == r.id }) else { continue }
            for c in plan.corners.map({ FloorMapView.transform($0, pl) }) {
                mn.x = min(mn.x, c.x); mn.y = min(mn.y, c.y); mx.x = max(mx.x, c.x); mx.y = max(mx.y, c.y)
            }
        }
        guard mn.x.isFinite else { return (30, .zero) }
        let w = max(mx.x - mn.x, 1), h = max(mx.y - mn.y, 1)
        let s = min((size.width - 40) / w, (size.height - 30) / h)
        return (s, CGPoint(x: size.width / 2 - (mn.x + mx.x) / 2 * s, y: size.height / 2 - (mn.y + mx.y) / 2 * s))
    }
}
