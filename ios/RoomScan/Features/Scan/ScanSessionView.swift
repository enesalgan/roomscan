import SwiftUI
import RoomPlan

/// Full-screen LiDAR scan: scan → stop → RoomPlan builds the model → saved automatically → caller opens the 2D plan.
/// Shutter button captures job photos from the live camera while scanning.
struct ScanSessionView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let job: Job
    var existingScans: Int = 0
    let onSaved: (Scan) -> Void
    var onPhoto: ((Photo) -> Void)? = nil

    @State private var controller = ScanController()
    @State private var saving = false
    @State private var saveError: String?
    @State private var showPaywall = false
    @State private var photoCount = 0
    @State private var flash = false
    @State private var lastThumb: UIImage?

    var body: some View {
        ZStack {
            RoomCaptureViewRepresentable(controller: controller)
                .ignoresSafeArea()

            if flash { Color.white.ignoresSafeArea().transition(.opacity) }

            VStack {
                topBar
                Spacer()
                if let text = controller.instructionText, controller.phase == .scanning {
                    Text(text)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.bottom, 10)
                }
                bottomBar
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            if controller.phase == .processing || saving {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(saving ? "Saving…" : "Building room model…").font(.subheadline.bold()).foregroundStyle(.white)
                }
                .padding(24).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onChange(of: controller.phase) { _, phase in
            if phase == .done { Task { await save() } }
        }
        .sheet(isPresented: $showPaywall, onDismiss: { dismiss() }) { PaywallView() }
        .alert("Scan error", isPresented: Binding(get: { controller.error != nil || saveError != nil },
                                                 set: { if !$0 { controller.error = nil; saveError = nil } })) {
            Button("OK") { if saveError != nil { dismiss() } }
        } message: { Text(controller.error ?? saveError ?? "") }
    }

    // MARK: UI

    private var topBar: some View {
        HStack(alignment: .top) {
            Button { controller.cancel(); dismiss() } label: {
                Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(.black.opacity(0.45), in: Circle())
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(controller.phase == .scanning ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(statusText).font(.caption.weight(.semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
    }

    private var statusText: String {
        guard let live = controller.liveRoom, controller.phase == .scanning else { return "Starting…" }
        return "\(live.walls.count) walls · \(live.doors.count) doors · \(live.windows.count) windows"
    }

    private var bottomBar: some View {
        HStack {
            // photo count / last thumbnail
            ZStack {
                if let lastThumb {
                    Image(uiImage: lastThumb).resizable().scaledToFill()
                        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 1.5))
                }
                if photoCount > 0 {
                    Text("\(photoCount)").font(.caption2.bold()).foregroundStyle(.white)
                        .padding(5).background(Color.accentColor, in: Circle())
                        .offset(x: 18, y: -18)
                }
            }
            .frame(width: 56, height: 56)

            Spacer()

            // stop scanning
            Button { controller.stop() } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                    RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 30, height: 30)
                }
            }
            .disabled(controller.phase != .scanning)

            Spacer()

            // shutter
            Button { capturePhoto() } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 3).frame(width: 56, height: 56)
                    Circle().fill(.white).frame(width: 44, height: 44)
                }
            }
            .disabled(controller.phase != .scanning)
        }
        .padding(.bottom, 6)
    }

    // MARK: Actions

    private func capturePhoto() {
        guard let image = controller.capturePhoto(), let userId = session.userId else { return }
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { withAnimation { flash = false } }
        lastThumb = image.resized(maxDimension: 200)
        photoCount += 1
        Task {
            if let p = try? await Repository.addPhoto(jobId: job.id, orgId: job.orgId, userId: userId, image: image) { onPhoto?(p) }
        }
    }

    private func save() async {
        guard let room = controller.finalRoom, let userId = session.userId else { return }
        saving = true; defer { saving = false }
        do {
            let built = RoomSummaryBuilder.build(from: room)
            let plan = FloorPlanBuilder.build(from: room)
            let files = try RoomSummaryBuilder.export(room, name: "room")
            let scan = Scan(jobId: job.id, orgId: job.orgId, createdBy: userId,
                            name: "Room \(existingScans + 1)",
                            floorAreaM2: plan?.area ?? built.floorAreaM2,
                            summary: plan?.summary ?? built.summary,
                            plan: plan)
            let saved = try await Repository.saveScan(scan, usdzURL: files.usdz, jsonData: files.json, thumbnail: controller.snapshot())
            try? FileManager.default.removeItem(at: files.usdz)
            if job.status == .new || job.status == .scheduled { try? await Repository.update(jobId: job.id, status: .measured) }
            onSaved(saved)
            dismiss()
        } catch let e as AppError {
            if case .scanLimitReached = e { showPaywall = true } else { saveError = e.localizedDescription }
        } catch {
            saveError = error.localizedDescription
        }
    }
}
