import SwiftUI
import QuickLook
import SceneKit
import RoomPlan

/// Scan workspace: 2D plan editor · wall elevations · 3D from plan · raw LiDAR mesh.
struct ScanPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State var scan: Scan
    var onUpdated: (Scan) -> Void = { _ in }
    var onAddRoom: (() -> Void)? = nil

    enum Mode: String, CaseIterable, Identifiable {
        case plan = "2D", walls = "Walls", model = "3D", mesh = "Scan"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .plan
    @State private var plan: FloorPlan?
    @State private var selection: PlanSelection?
    @State private var wallIndex = 0
    @State private var history: [FloorPlan] = []
    @State private var future: [FloorPlan] = []
    @State private var dirty = false
    @State private var saving = false
    @State private var modelURL: URL?
    @State private var previewItem: URL?
    @State private var error: String?
    @State private var loading = true
    @State private var refitToken = 0
    @State private var measureMode = false
    @State private var showStylePicker = false
    @State private var dimEdit: DimEdit?
    @State private var share: ShareItems?

    private struct DimEdit: Identifiable {
        let id = UUID()
        let target: DimensionTarget
        let meters: Double
        let title: String
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal).padding(.vertical, 6)

                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                bottomPanel
            }
            .sheet(item: $share) { ShareSheet(items: $0.urls) }
            .sheet(item: $dimEdit) { d in
                MeasurementSheet(title: d.title, meters: d.meters) { m in apply(d.target, m) }
            }
            .navigationTitle($scan.name)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: scan.name) { _, _ in dirty = true }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(dirty ? String(localized: "Discard") : String(localized: "Close")) { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(history.isEmpty)
                    Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(future.isEmpty)
                    Button { measureMode.toggle(); if measureMode { mode = .plan; selection = nil } } label: {
                        Image(systemName: "ruler").foregroundStyle(measureMode ? Color.accentColor : .primary)
                    }
                    Menu {
                        Button { edit { $0 = $0.straightened() }; selection = nil; refitToken += 1 } label: { Label("Square up walls", systemImage: "square.on.square.dashed") }
                        Divider()
                        if let plan {
                            Button { share = ShareItems(urls: CADExport.files(for: scan, plan: plan, formats: ["dxf"])) } label: { Label("Export DXF (2020 / AutoCAD)", systemImage: "square.and.arrow.up") }
                            Button { share = ShareItems(urls: CADExport.files(for: scan, plan: plan, formats: ["svg"])) } label: { Label("Export SVG", systemImage: "square.and.arrow.up") }
                        }
                        if let modelURL {
                            Button { previewItem = modelURL } label: { Label("View scan in AR", systemImage: "arkit") }
                            ShareLink(item: modelURL) { Label("Share USDZ", systemImage: "square.and.arrow.up") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    Button { Task { await save() } } label: {
                        if saving { ProgressView() } else { Text("Save").bold() }
                    }
                    .disabled(!dirty || saving)
                }
            }
            .quickLookPreview($previewItem)
            .task { await load() }
            .onChange(of: selection) { _, s in
                if case .wall(let i) = s { wallIndex = i }
                if case .opening(let id) = s, let o = plan?.openings.first(where: { $0.id == id }) { wallIndex = o.wall }
            }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if loading {
            ProgressView("Preparing floor plan…")
        } else if let error, plan == nil {
            ContentUnavailableView("No floor plan", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            switch mode {
            case .plan:
                PlanEditorView(plan: planBinding, selection: $selection, onBeginEdit: pushHistory, onEndEdit: { dirty = true },
                               refitToken: refitToken, measureMode: $measureMode,
                               onDimensionTap: { t, m in dimEdit = DimEdit(target: t, meters: m, title: dimTitle(t)) })
                    .padding(.bottom, panelInset)
            case .walls:
                WallElevationView(plan: planBinding, wall: $wallIndex, selection: $selection, onBeginEdit: pushHistory, onEndEdit: { dirty = true })
                    .padding(.bottom, panelInset)
            case .model:
                if let plan { Plan3DView(plan: plan) }
            case .mesh:
                if let modelURL { USDZSceneView(url: modelURL) }
                else { ContentUnavailableView("Mesh not available", systemImage: "cube.transparent") }
            }
        }
    }

    private var planBinding: Binding<FloorPlan> {
        Binding(get: { plan ?? FloorPlan(corners: []) }, set: { plan = $0 })
    }

    // MARK: Bottom panel

    /// Space reserved under the plan so the floating panel never covers it
    private var panelInset: CGFloat {
        switch selection {
        case nil: return 150
        case .corner, .measurement: return 90
        default: return 180
        }
    }

    @ViewBuilder private var bottomPanel: some View {
        if let plan, mode == .plan || mode == .walls {
            PanelCard {
                switch selection {
                case .wall(let i):
                    WallPanel(plan: planBinding, wall: i, onEdit: edit, onShowElevation: { mode = .walls; wallIndex = i },
                              onAddCorner: { edit { $0.insertCorner(onWall: i) }; selection = .corner(i + 1) },
                              onClose: { selection = nil })
                case .opening(let id):
                    if let k = plan.openings.firstIndex(where: { $0.id == id }) {
                        OpeningPanel(plan: planBinding, index: k, onEdit: edit,
                                     onDelete: { let w = plan.openings[k].wall; edit { $0.openings.remove(at: k) }; selection = .wall(w) },
                                     onDuplicate: { var newId: UUID?; edit { newId = $0.duplicateOpening(id)?.id }; if let newId { selection = .opening(newId) } },
                                     onReplace: { showStylePicker = true },
                                     onClose: { selection = nil })
                        .sheet(isPresented: $showStylePicker) {
                            OpeningStylePicker(current: plan.openings[k]) { st in
                                edit { $0.openings[k].style = st.id; $0.openings[k].kind = st.kind }
                            }
                        }
                    }
                case .object(let id):
                    if let k = plan.objects.firstIndex(where: { $0.id == id }) {
                        ObjectPanel(plan: planBinding, index: k, onEdit: edit,
                                    onDelete: { edit { $0.objects.remove(at: k) }; selection = nil },
                                    onDuplicate: { var newId: UUID?; edit { newId = $0.duplicateObject(id)?.id }; if let newId { selection = .object(newId) } },
                                    onClose: { selection = nil })
                    }
                case .measurement(let id):
                    if let m = plan.measurements.first(where: { $0.id == id }) {
                        PanelHeader(symbol: "ruler", title: Measure.ftIn(m.length), subtitle: Measure.metric(m.length), onClose: { selection = nil }) {
                            RoundButton(symbol: "trash", tint: .red) { edit { $0.measurements.removeAll { $0.id == id } }; selection = nil }
                        }
                    }
                case .corner(let i):
                    PanelHeader(symbol: "arrow.up.and.down.and.arrow.left.and.right", title: String(localized: "Corner \(i + 1)"),
                                subtitle: String(localized: "Drag the handle to move it"), onClose: { selection = nil }) {
                        if plan.wallCount > 3 {
                            RoundButton(symbol: "trash", tint: .red) { edit { $0.removeCorner(i) }; selection = nil }
                        }
                    }
                case nil:
                    idleBar(plan)
                }
            }
        } else if let plan, mode == .model {
            PanelCard { statsRow(plan) }
        }
    }

    /// Nothing selected: Insert · Rotate · Measure · Square up, plus the room summary
    private func idleBar(_ plan: FloorPlan) -> some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) {
                Menu {
                    if let onAddRoom {
                        Section("Rooms") {
                            Button { onAddRoom() } label: { Label("Scan another room", systemImage: "cube.transparent") }
                        }
                    }
                    Section("Openings") {
                        ForEach(OpeningKind.allCases) { kind in
                            Button { insert(kind) } label: { Label(kind.title, systemImage: kind.systemImage) }
                        }
                    }
                    Section("Objects") {
                        ForEach(["Cabinet", "Island", "Appliance", "Fixture", "Furniture"], id: \.self) { name in
                            Button { insertObject(name) } label: { Label(LocalizedStringKey(name), systemImage: "square.dashed") }
                        }
                    }
                } label: { ChipLabel(symbol: "plus", title: "Insert", prominent: true) }
                .buttonStyle(.plain)
                ActionChip(symbol: "rotate.right", title: "Rotate") { edit { $0.rotate90() }; refitToken += 1 }
                ActionChip(symbol: "ruler", title: "Measure", active: measureMode) { measureMode.toggle() }
                ActionChip(symbol: "square.on.square.dashed", title: "Square up") { edit { $0 = $0.straightened() }; refitToken += 1 }
            } }
            statsRow(plan)
        }
    }

    private func statsRow(_ plan: FloorPlan) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                stat("Size", "\(Measure.ftIn(plan.width)) × \(Measure.ftIn(plan.depth))")
                stat("Area", plan.area.squareFeet)
                stat("Ceiling", Measure.ftIn(plan.wallHeight))
                stat("Perimeter", Measure.ftIn(plan.perimeter))
                stat("Doors / Windows", "\(plan.summary.doors) / \(plan.summary.windows)")
                stat("Metric", "\(Measure.metric(plan.width)) × \(Measure.metric(plan.depth))")
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(title)).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Insert / dimension editing

    private func insert(_ kind: OpeningKind) {
        guard let plan else { return }
        // longest scanned wall
        let wall = (0..<plan.wallCount).filter { !plan.isInferred($0) }.max { plan.wallLength($0) < plan.wallLength($1) } ?? 0
        var newId: UUID?
        edit { newId = $0.addOpening(kind, on: wall).id }
        if let newId { selection = .opening(newId) }
    }

    private func insertObject(_ name: String) {
        var newId: UUID?
        edit { newId = $0.addObject(name).id }
        if let newId { selection = .object(newId) }
    }

    private func dimTitle(_ t: DimensionTarget) -> String {
        switch t {
        case .wall: String(localized: "Wall length")
        case .openingWidth: String(localized: "Width")
        case .openingLeft: String(localized: "From left")
        case .openingRight: String(localized: "From right")
        case .objectSide(_, let s): String(localized: "Distance to wall") + " · " + s
        }
    }

    private func apply(_ t: DimensionTarget, _ m: Double) {
        switch t {
        case .wall(let i):
            edit { $0.setWallLength(i, max(0.1, m)) }
        case .openingWidth(let id):
            edit { p in if let k = p.openings.firstIndex(where: { $0.id == id }) { p.openings[k].width = max(0.1, m); p.clampOpenings(on: p.openings[k].wall) } }
        case .openingLeft(let id):
            edit { p in if let k = p.openings.firstIndex(where: { $0.id == id }) { p.openings[k].offset = max(0, m) + p.openings[k].width / 2; p.clampOpenings(on: p.openings[k].wall) } }
        case .openingRight(let id):
            edit { p in
                if let k = p.openings.firstIndex(where: { $0.id == id }) {
                    p.openings[k].offset = p.wallLength(p.openings[k].wall) - max(0, m) - p.openings[k].width / 2
                    p.clampOpenings(on: p.openings[k].wall)
                }
            }
        case .objectSide(let id, let side):
            edit { p in
                guard let k = p.objects.firstIndex(where: { $0.id == id }) else { return }
                let o = p.objects[k]
                guard let s = p.objectSides(o).first(where: { $0.side == side }), let hit = p.rayToWall(from: s.point, direction: s.dir) else { return }
                p.objects[k].center = o.center + s.dir * (hit.distance - max(0, m))
            }
        }
    }

    // MARK: Editing / history

    private func pushHistory() {
        guard let plan else { return }
        history.append(plan)
        if history.count > 50 { history.removeFirst() }
        future.removeAll()
    }

    private func edit(_ change: (inout FloorPlan) -> Void) {
        guard var p = plan else { return }
        pushHistory()
        change(&p)
        plan = p
        dirty = true
    }

    private func undo() {
        guard let last = history.popLast(), let current = plan else { return }
        future.append(current); plan = last; dirty = true
    }

    private func redo() {
        guard let next = future.popLast(), let current = plan else { return }
        history.append(current); plan = next; dirty = true
    }

    // MARK: Load / save

    private func load() async {
        defer { loading = false }
        modelURL = try? await Repository.localUSDZ(for: scan)
        if let p = scan.plan { plan = p; return }
        do {
            let data = try await Repository.scanJSON(for: scan)
            let room = try JSONDecoder().decode(CapturedRoom.self, from: data)
            if let built = FloorPlanBuilder.build(from: room) {
                plan = built
                dirty = true   // first-time plan → offer to save it
            } else {
                error = "RoomPlan didn't return enough walls to build a plan."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        guard let plan else { return }
        saving = true; defer { saving = false }
        var updated = scan
        updated.plan = plan
        updated.summary = plan.summary
        updated.floorAreaM2 = plan.area
        do {
            scan = try await Repository.updateScan(updated)
            onUpdated(scan)
            dirty = false
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Panel chrome

/// Floating bottom card (rounded top, elevated background — readable in light and dark)
private struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .overlay(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))
                    .ignoresSafeArea(edges: .bottom)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, y: -4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct PanelHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    var onClose: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            trailing
            RoundButton(symbol: "xmark", action: onClose)
        }
    }
}

private struct RoundButton: View {
    let symbol: String
    var tint: Color = .primary
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                .frame(width: 36, height: 36).background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Pill label used in the idle bar and panels (wrap in Button / Menu)
private struct ChipLabel: View {
    let symbol: String
    let title: LocalizedStringKey
    var prominent = false
    var active = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.subheadline.weight(.semibold))
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .padding(.horizontal, 14).frame(height: 40)
        .foregroundStyle(prominent ? Color(.systemBackground) : (active ? Color.accentColor : .primary))
        .background(prominent ? Color.primary : (active ? Color.accentColor.opacity(0.14) : Color(.tertiarySystemFill)), in: Capsule())
        .contentShape(Capsule())
    }
}

private struct ActionChip: View {
    let symbol: String
    let title: LocalizedStringKey
    var active = false
    var action: () -> Void
    var body: some View {
        Button(action: action) { ChipLabel(symbol: symbol, title: title, active: active) }.buttonStyle(.plain)
    }
}

// MARK: - Panels

private struct WallPanel: View {
    @Binding var plan: FloorPlan
    let wall: Int
    var onEdit: ((inout FloorPlan) -> Void) -> Void
    var onShowElevation: () -> Void
    var onAddCorner: () -> Void
    var onClose: () -> Void

    var body: some View {
        PanelHeader(symbol: "line.diagonal", title: String(localized: "Wall \(wall + 1)"),
                    subtitle: plan.isInferred(wall) ? String(localized: "not scanned") : "\(plan.openings(on: wall).count) " + String(localized: "openings"),
                    onClose: onClose) {
            RoundButton(symbol: "rectangle.portrait.and.arrow.right", tint: .accentColor, action: onShowElevation)
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                MeasureTile(title: String(localized: "Length"), meters: plan.wallLength(wall), tint: .accentColor) { m in onEdit { $0.setWallLength(wall, m) } }
                MeasureTile(title: String(localized: "Ceiling"), meters: plan.wallHeight) { m in onEdit { $0.wallHeight = m } }
                Divider().frame(height: 30)
                ForEach(OpeningKind.allCases) { kind in
                    ActionChip(symbol: kind.systemImage, title: LocalizedStringKey(kind.title)) { onEdit { $0.addOpening(kind, on: wall) } }
                }
                ActionChip(symbol: "plus.viewfinder", title: "Add corner", action: onAddCorner)
            }
        }
    }
}

private struct OpeningPanel: View {
    @Binding var plan: FloorPlan
    let index: Int
    var onEdit: ((inout FloorPlan) -> Void) -> Void
    var onDelete: () -> Void
    var onDuplicate: () -> Void
    var onReplace: () -> Void
    var onClose: () -> Void

    private var o: PlanOpening { plan.openings[index] }

    var body: some View {
        let st = OpeningCatalog.style(for: o)
        PanelHeader(symbol: st.symbol, title: String(localized: String.LocalizationValue(st.name)),
                    subtitle: String(localized: "Wall \(o.wall + 1)"), onClose: onClose) {
            RoundButton(symbol: "arrow.triangle.2.circlepath", tint: .accentColor, action: onReplace)
            RoundButton(symbol: "plus.square.on.square", action: onDuplicate)
            RoundButton(symbol: "trash", tint: .red, action: onDelete)
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                MeasureTile(title: String(localized: "Width"), meters: o.width, tint: .accentColor) { m in
                    onEdit { $0.openings[index].width = max(0.1, m); $0.clampOpenings(on: o.wall) }
                }
                MeasureTile(title: String(localized: "Height"), meters: o.height) { m in onEdit { $0.openings[index].height = max(0.1, m) } }
                MeasureTile(title: String(localized: "Sill"), meters: o.sill) { m in onEdit { $0.openings[index].sill = max(0, m) } }
                MeasureTile(title: String(localized: "From left"), meters: o.left) { m in
                    onEdit { $0.openings[index].offset = m + o.width / 2; $0.clampOpenings(on: o.wall) }
                }
                MeasureTile(title: String(localized: "From right"), meters: plan.wallLength(o.wall) - o.right) { m in
                    onEdit { $0.openings[index].offset = plan.wallLength(o.wall) - m - o.width / 2; $0.clampOpenings(on: o.wall) }
                }
            }
        }
    }
}

private struct ObjectPanel: View {
    @Binding var plan: FloorPlan
    let index: Int
    var onEdit: ((inout FloorPlan) -> Void) -> Void
    var onDelete: () -> Void
    var onDuplicate: () -> Void
    var onClose: () -> Void
    @State private var renaming = false

    private var o: PlanObject { plan.objects[index] }

    var body: some View {
        PanelHeader(symbol: "square.dashed", title: o.category.capitalized,
                    subtitle: "\(Measure.ftIn(o.width)) × \(Measure.ftIn(o.depth)) × \(Measure.ftIn(o.height))", onClose: onClose) {
            RoundButton(symbol: "pencil") { renaming = true }
            RoundButton(symbol: "rotate.right") { onEdit { $0.objects[index].rotation += .pi / 2 } }
            RoundButton(symbol: "plus.square.on.square", action: onDuplicate)
            RoundButton(symbol: "trash", tint: .red, action: onDelete)
        }
        .alert("Name", isPresented: $renaming) {
            TextField("Name", text: Binding(get: { o.category.capitalized }, set: { v in onEdit { $0.objects[index].category = v } }))
            Button("Done") {}
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                MeasureTile(title: String(localized: "Width"), meters: o.width, tint: .accentColor) { m in onEdit { $0.objects[index].width = max(0.05, m) } }
                MeasureTile(title: String(localized: "Depth"), meters: o.depth) { m in onEdit { $0.objects[index].depth = max(0.05, m) } }
                MeasureTile(title: String(localized: "Height"), meters: o.height) { m in onEdit { $0.objects[index].height = max(0.05, m) } }
                Divider().frame(height: 30)
                // distance to the wall on each side — editing slides the object
                ForEach(plan.objectSides(o)) { side in
                    if let hit = plan.rayToWall(from: side.point, direction: side.dir) {
                        MeasureTile(title: sideTitle(side.side), meters: hit.distance) { m in
                            onEdit { $0.objects[index].center = o.center + side.dir * (hit.distance - max(0, m)) }
                        }
                    }
                }
            }
        }
    }

    private func sideTitle(_ s: String) -> String {
        switch s {
        case "left": String(localized: "To left wall")
        case "right": String(localized: "To right wall")
        case "front": String(localized: "To front wall")
        default: String(localized: "To back wall")
        }
    }
}

/// SceneKit viewer for the raw RoomPlan USDZ mesh
struct USDZSceneView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling4X
        if let scene = try? SCNScene(url: url) {
            v.scene = scene
            let (center, radius) = scene.rootNode.boundingSphere
            let cam = SCNNode()
            cam.camera = SCNCamera()
            cam.camera?.zFar = 1000
            cam.position = SCNVector3(center.x + radius * 1.2, center.y + radius * 1.4, center.z + radius * 1.6)
            cam.look(at: center)
            scene.rootNode.addChildNode(cam)
            v.pointOfView = cam
        }
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}
