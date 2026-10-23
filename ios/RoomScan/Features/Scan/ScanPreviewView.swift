import SwiftUI
import QuickLook
import SceneKit
import RoomPlan

/// Scan workspace: 2D plan editor · wall elevations · 3D from plan · raw LiDAR mesh.
struct ScanPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State var scan: Scan
    var onUpdated: (Scan) -> Void = { _ in }

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 6)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomPanel
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
                    Menu {
                        Button { edit { $0 = $0.straightened() }; selection = nil; refitToken += 1 } label: { Label("Square up walls", systemImage: "square.on.square.dashed") }
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
                PlanEditorView(plan: planBinding, selection: $selection, onBeginEdit: pushHistory, onEndEdit: { dirty = true }, refitToken: refitToken)
            case .walls:
                WallElevationView(plan: planBinding, wall: $wallIndex, selection: $selection, onBeginEdit: pushHistory, onEndEdit: { dirty = true })
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

    @ViewBuilder private var bottomPanel: some View {
        if let plan, mode == .plan || mode == .walls {
            VStack(spacing: 0) {
                Divider()
                switch selection {
                case .wall(let i):
                    WallPanel(plan: planBinding, wall: i, onEdit: edit) { mode = .walls; wallIndex = i }
                case .opening(let id):
                    if let k = plan.openings.firstIndex(where: { $0.id == id }) {
                        OpeningPanel(plan: planBinding, index: k, onEdit: edit, onDelete: {
                            edit { $0.openings.remove(at: k) }; selection = .wall(plan.openings[k].wall)
                        })
                    }
                case .object(let id):
                    if let k = plan.objects.firstIndex(where: { $0.id == id }) {
                        ObjectPanel(plan: planBinding, index: k, onEdit: edit, onDelete: {
                            edit { $0.objects.remove(at: k) }; selection = nil
                        })
                    }
                case .corner(let i):
                    HStack {
                        Label("Corner \(i + 1) — drag to move", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                        Spacer()
                        Button("Done") { selection = nil }
                    }
                    .padding()
                case nil:
                    summaryRow(plan)
                }
            }
            .background(.regularMaterial)
        } else if let plan, mode == .model {
            VStack(spacing: 0) { Divider(); summaryRow(plan) }.background(.regularMaterial)
        }
    }

    private func summaryRow(_ plan: FloorPlan) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                stat("Size", "\(Measure.ftIn(plan.width)) × \(Measure.ftIn(plan.depth))")
                stat("Area", plan.area.squareFeet)
                stat("Ceiling", Measure.ftIn(plan.wallHeight))
                stat("Perimeter", Measure.ftIn(plan.perimeter))
                stat("Walls", "\(plan.wallCount)")
                stat("Doors / Windows", "\(plan.summary.doors) / \(plan.summary.windows)")
                stat("Metric", "\(Measure.metric(plan.width)) × \(Measure.metric(plan.depth))")
            }
            .padding(.horizontal).padding(.vertical, 10)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold()).monospacedDigit()
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

// MARK: - Panels

private struct WallPanel: View {
    @Binding var plan: FloorPlan
    let wall: Int
    var onEdit: ((inout FloorPlan) -> Void) -> Void
    var onShowElevation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Wall \(wall + 1)").font(.headline)
                Spacer()
                MeasureField(title: "Length", meters: plan.wallLength(wall)) { m in onEdit { $0.setWallLength(wall, m) } }
            }
            HStack(spacing: 8) {
                ForEach(OpeningKind.allCases) { kind in
                    Button { onEdit { $0.addOpening(kind, on: wall) } } label: {
                        Label(kind.title, systemImage: kind.systemImage).font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button(action: onShowElevation) { Label("Wall view", systemImage: "rectangle.portrait.and.arrow.right").font(.caption) }
                    .buttonStyle(.borderedProminent)
            }
            HStack {
                MeasureField(title: "Ceiling", meters: plan.wallHeight) { m in onEdit { $0.wallHeight = m } }
                Spacer()
                Text("\(plan.openings(on: wall).count) openings").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

private struct OpeningPanel: View {
    @Binding var plan: FloorPlan
    let index: Int
    var onEdit: ((inout FloorPlan) -> Void) -> Void
    var onDelete: () -> Void

    private var o: PlanOpening { plan.openings[index] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Type", selection: Binding(get: { o.kind }, set: { k in onEdit { $0.openings[index].kind = k } })) {
                    ForEach(OpeningKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 260)
                Spacer()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
            }
            HStack(spacing: 12) {
                MeasureField(title: "Width", meters: o.width) { m in
                    onEdit { $0.openings[index].width = max(0.1, m); $0.clampOpenings(on: o.wall) }
                }
                MeasureField(title: "Height", meters: o.height) { m in onEdit { $0.openings[index].height = max(0.1, m) } }
                MeasureField(title: "Sill", meters: o.sill) { m in onEdit { $0.openings[index].sill = max(0, m) } }
                MeasureField(title: "From left", meters: o.left) { m in
                    onEdit { $0.openings[index].offset = m + o.width / 2; $0.clampOpenings(on: o.wall) }
                }
            }
        }
        .padding()
    }
}

private struct ObjectPanel: View {
    @Binding var plan: FloorPlan
    let index: Int
    var onEdit: ((inout FloorPlan) -> Void) -> Void
    var onDelete: () -> Void

    private var o: PlanObject { plan.objects[index] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Name", text: Binding(get: { o.category.capitalized }, set: { v in onEdit { $0.objects[index].category = v } }))
                    .font(.headline).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Spacer()
                Button { onEdit { $0.objects[index].rotation += .pi / 2 } } label: { Image(systemName: "rotate.right") }
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
            }
            HStack(spacing: 12) {
                MeasureField(title: "Width", meters: o.width) { m in onEdit { $0.objects[index].width = max(0.05, m) } }
                MeasureField(title: "Depth", meters: o.depth) { m in onEdit { $0.objects[index].depth = max(0.05, m) } }
                MeasureField(title: "Height", meters: o.height) { m in onEdit { $0.objects[index].height = max(0.05, m) } }
                Spacer()
                Text("Drag to move").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

/// Small labeled text field showing feet-inches; commits parsed value on return.
struct MeasureField: View {
    let title: String
    let meters: Double
    var onCommit: (Double) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField("", text: $text)
                .font(.subheadline.monospacedDigit())
                .textFieldStyle(.roundedBorder)
                .frame(width: 92)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(commit)
                .onChange(of: focused) { _, f in if !f { commit() } }
        }
        .onAppear { text = Measure.ftIn(meters) }
        .onChange(of: meters) { _, m in if !focused { text = Measure.ftIn(m) } }
    }

    private func commit() {
        if let m = Measure.parse(text), abs(m - meters) > 0.001 { onCommit(m) }
        text = Measure.ftIn(Measure.parse(text) ?? meters)
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
