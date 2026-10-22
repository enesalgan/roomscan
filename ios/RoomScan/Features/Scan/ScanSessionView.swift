import SwiftUI
import RoomPlan

/// Full-screen LiDAR scan flow: scan → process → review & name → upload.
struct ScanSessionView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let job: Job
    let onSaved: (Scan) -> Void

    @State private var controller = ScanController()
    @State private var roomName = "Kitchen"
    @State private var saving = false
    @State private var saveError: String?
    @State private var showPaywall = false

    var body: some View {
        ZStack {
            RoomCaptureViewRepresentable(controller: controller)
                .ignoresSafeArea()
                .onAppear { DispatchQueue.main.async { controller.start() } }

            VStack {
                topBar
                Spacer()
                if let text = controller.instructionText, controller.phase == .scanning {
                    Text(text)
                        .font(.subheadline.bold())
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 8)
                }
                bottomBar
            }
            .padding()

            if controller.phase == .processing {
                ProgressView("Building 3D model…")
                    .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .sheet(isPresented: Binding(get: { controller.phase == .done }, set: { _ in })) {
            reviewSheet
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .alert("Scan error", isPresented: Binding(get: { controller.error != nil }, set: { if !$0 { controller.error = nil } })) {
            Button("OK") {}
        } message: { Text(controller.error ?? "") }
    }

    private var topBar: some View {
        HStack {
            Button { controller.cancel(); dismiss() } label: {
                Image(systemName: "xmark").font(.headline).padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            if let live = controller.liveRoom, controller.phase == .scanning {
                Text("\(live.walls.count) walls · \(live.doors.count) doors · \(live.windows.count) windows")
                    .font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private var bottomBar: some View {
        Group {
            if controller.phase == .scanning {
                Button { controller.stop() } label: {
                    Text("Done scanning").font(.headline).frame(maxWidth: .infinity).padding()
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private var reviewSheet: some View {
        NavigationStack {
            Form {
                if let room = controller.finalRoom {
                    let built = RoomSummaryBuilder.build(from: room)
                    let summary = built.summary
                    let area = built.floorAreaM2
                    Section("Room") {
                        TextField("Name", text: $roomName)
                    }
                    Section("Measurements") {
                        LabeledContent("Size", value: "\(summary.widthM.feetInches) × \(summary.depthM.feetInches)")
                        LabeledContent("Ceiling", value: summary.heightM.feetInches)
                        LabeledContent("Floor area", value: area.squareFeet)
                        LabeledContent("Perimeter", value: summary.perimeterM.feetInches)
                        LabeledContent("Walls / Doors / Windows", value: "\(summary.walls) / \(summary.doors) / \(summary.windows)")
                        if !summary.objects.isEmpty {
                            LabeledContent("Objects", value: summary.objects.map { "\($0.value) \($0.key)" }.sorted().joined(separator: ", "))
                        }
                    }
                    if let saveError { Text(saveError).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Review scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if saving { ProgressView() } else { Text("Save & upload").bold() }
                    }.disabled(saving)
                }
            }
        }
    }

    private func save() async {
        guard let room = controller.finalRoom, let userId = session.userId else { return }
        saving = true; defer { saving = false }
        do {
            let built = RoomSummaryBuilder.build(from: room)
            let plan = FloorPlanBuilder.build(from: room)
            let files = try RoomSummaryBuilder.export(room, name: roomName)
            let scan = Scan(jobId: job.id, orgId: job.orgId, createdBy: userId,
                            name: roomName.nilIfEmpty ?? "Room",
                            floorAreaM2: plan?.area ?? built.floorAreaM2,
                            summary: plan?.summary ?? built.summary,
                            plan: plan)
            let saved = try await Repository.saveScan(scan, usdzURL: files.usdz, jsonData: files.json, thumbnail: controller.snapshot())
            try? FileManager.default.removeItem(at: files.usdz)
            onSaved(saved)
            if job.status == .new || job.status == .scheduled { try? await Repository.update(jobId: job.id, status: .measured) }
            dismiss()
        } catch let e as AppError {
            if case .scanLimitReached = e { showPaywall = true }
            saveError = e.localizedDescription
        } catch {
            saveError = error.localizedDescription
        }
    }
}
