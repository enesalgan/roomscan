import SwiftUI
import MapKit
import RoomPlan

struct JobDetailView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    let jobId: UUID
    var autoStartScan = false
    var autoRoomName: String? = nil

    @State private var job: Job?
    @State private var didAutoStart = false
    @State private var scans: [Scan] = []
    @State private var photos: [Photo] = []
    @State private var error: String?
    @State private var showEdit = false
    @State private var showScanner = false
    @State private var showPaywall = false
    @State private var scanToPreview: Scan?
    @State private var confirmDelete = false
    @State private var showFloorMap = false
    @State private var showRoomPicker = false
    @State private var pendingRoomName: String?
    @State private var renaming = false
    @State private var newTitle = ""

    var body: some View {
        Group {
            if let job {
                List {
                    headerSection(job)
                    customerSection(job)
                    floorPlanSection(job)
                    scansSection(job)
                    PhotosSection(job: job, photos: $photos)
                    if let n = job.notes, !n.isEmpty { Section("Notes") { Text(n) } }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { newTitle = job.title; renaming = true } label: { Label("Rename", systemImage: "textformat") }
                            Button { showEdit = true } label: { Label("Edit details", systemImage: "pencil") }
                            Menu("Status") {
                                ForEach(JobStatus.allCases) { s in
                                    Button { Task { await setStatus(s) } } label: {
                                        Label(s.title, systemImage: s.systemImage)
                                    }
                                }
                            }
                            Divider()
                            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete job", systemImage: "trash") }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
                .sheet(isPresented: $showEdit) {
                    JobEditView(job: job) { self.job = $0 }
                }
                .alert("Rename job", isPresented: $renaming) {
                    TextField("Name", text: $newTitle)
                    Button("Save") { Task { await rename(newTitle) } }
                    Button("Cancel", role: .cancel) {}
                }
                .sheet(isPresented: $showRoomPicker) {
                    RoomTypeSheet(existing: scans.map(\.name)) { name in
                        pendingRoomName = name
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showScanner = true }
                    }
                }
                .fullScreenCover(isPresented: $showScanner) {
                    ScanSessionView(job: job, existingScans: scans.count, roomName: pendingRoomName, onSaved: { saved in
                        scans.insert(saved, at: 0)
                        if job.status == .new || job.status == .scheduled { self.job?.status = .measured }
                        Task {
                            await session.refreshEntitlement()
                            if let fresh = try? await Repository.job(id: jobId) { self.job = fresh }   // name/address filled in meanwhile
                        }
                        // open the 2D plan right away
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { scanToPreview = saved }
                    }, onPhoto: { p in photos.append(p) })
                    .onDisappear { pendingRoomName = nil }
                }
                .sheet(isPresented: $showPaywall) { PaywallView() }
                .fullScreenCover(isPresented: $showFloorMap) {
                    FloorMapView(job: job, scans: scans) { self.job = $0 }
                }
                .fullScreenCover(item: $scanToPreview) { s in
                    ScanPreviewView(scan: s, onUpdated: { updated in
                        if let i = scans.firstIndex(where: { $0.id == updated.id }) { scans[i] = updated }
                    }, onAddRoom: {
                        scanToPreview = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { startScan() }
                    })
                }
                .confirmationDialog("Delete this job?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { Task { await deleteJob() } }
                }
            } else {
                ProgressView()
            }
        }
        .task { await load() }
    }

    // MARK: Sections

    @ViewBuilder private func headerSection(_ job: Job) -> some View {
        Section {
            Button { newTitle = job.title; renaming = true } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(job.title).font(.title2.weight(.bold)).fontDesign(.rounded).foregroundStyle(.primary).lineLimit(2)
                    Image(systemName: "pencil").font(.subheadline).foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            HStack {
                StatusChip(status: job.status)
                Spacer()
                if let d = job.scheduledAt {
                    Label(d.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar").font(.footnote)
                }
            }
            if let e = job.estimateAmount {
                LabeledContent("Estimate", value: e, format: .currency(code: job.estimateCurrency))
            }
            if let lat = job.latitude, let lng = job.longitude {
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                Map(initialPosition: .region(MKCoordinateRegion(center: coord, span: .init(latitudeDelta: 0.005, longitudeDelta: 0.005)))) {
                    Marker(job.title, coordinate: coord)
                }
                .frame(height: 150).listRowInsets(EdgeInsets())
            }
            Button { showEdit = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "mappin.and.ellipse").foregroundStyle(Color.accentColor).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        if job.addressSummary.isEmpty {
                            Text("Add address").foregroundStyle(Color.accentColor)
                        } else {
                            Text([job.addressLine1, job.addressLine2].compactMap { $0?.nilIfEmpty }.joined(separator: ", ")).foregroundStyle(.primary)
                            Text([job.city, job.state, job.postalCode].compactMap { $0?.nilIfEmpty }.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !job.addressSummary.isEmpty {
                        Button { openInMaps(job) } label: {
                            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill").font(.body)
                                .frame(width: 34, height: 34).background(Color.accentColor.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.borderless)
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func customerSection(_ job: Job) -> some View {
        if job.customerName != nil || job.customerPhone != nil || job.customerEmail != nil {
            Section("Customer") {
                if let n = job.customerName { Label(n, systemImage: "person") }
                if let p = job.customerPhone, let url = URL(string: "tel:\(p.filter { !$0.isWhitespace })") {
                    Link(destination: url) { Label(p, systemImage: "phone") }
                }
                if let e = job.customerEmail, let url = URL(string: "mailto:\(e)") {
                    Link(destination: url) { Label(e, systemImage: "envelope") }
                }
            }
        }
    }

    @ViewBuilder private func floorPlanSection(_ job: Job) -> some View {
        if scans.contains(where: { $0.plan != nil }) {
            Section {
                Button { showFloorMap = true } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        FloorMapPreview(job: job, scans: scans)
                            .frame(height: 170)
                            .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                        HStack {
                            Label("Floor plan", systemImage: "square.split.bottomrightquarter").font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(scans.filter { $0.plan != nil }.count) rooms · arrange").font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func scansSection(_ job: Job) -> some View {
        Section {
            Button {
                startScan()
            } label: {
                Label(scans.isEmpty ? "Scan a room with LiDAR" : "Scan another room", systemImage: "cube.transparent")
                    .font(.headline)
            }
            ForEach(scans) { scan in
                Button { scanToPreview = scan } label: {
                    HStack(spacing: 12) {
                        ScanThumbnail(scan: scan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scan.name).font(.headline).foregroundStyle(.primary)
                            Text("\(scan.summary.widthM.feetInches) × \(scan.summary.depthM.feetInches)  ·  \(scan.summary.walls) walls, \(scan.summary.doors) doors, \(scan.summary.windows) windows")
                                .font(.footnote).foregroundStyle(.secondary)
                            if let a = scan.floorAreaM2 {
                                Text(a.squareFeet).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
            }
            .onDelete { idx in Task { await deleteScans(at: idx) } }
        } header: {
            HStack {
                Text("Room scans")
                Spacer()
                if !session.entitlement.subscribed {
                    Text("\(session.entitlement.scansRemaining ?? 0) free left").textCase(nil)
                }
            }
        }
    }

    // MARK: Actions

    private func startScan() {
        guard RoomCaptureSession.isSupported else { error = AppError.lidarUnsupported.localizedDescription; return }
        guard session.entitlement.canScan else { showPaywall = true; return }
        if pendingRoomName == nil { showRoomPicker = true } else { showScanner = true }
    }

    private func rename(_ title: String) async {
        guard var j = job, let t = title.nilIfEmpty, t != j.title else { return }
        j.title = t
        do { job = try await Repository.upsert(j) } catch { self.error = error.localizedDescription }
    }

    private func load() async {
        do {
            async let j = Repository.job(id: jobId)
            async let s = Repository.scans(jobId: jobId)
            async let p = Repository.photos(jobId: jobId)
            job = try await j; scans = try await s; photos = try await p
            if autoStartScan && !didAutoStart {
                didAutoStart = true
                pendingRoomName = autoRoomName          // room was picked on the Home sheet
                try? await Task.sleep(for: .milliseconds(300))
                startScan()
            }
        } catch { self.error = error.localizedDescription }
    }

    private func setStatus(_ s: JobStatus) async {
        do { try await Repository.update(jobId: jobId, status: s); job?.status = s }
        catch { self.error = error.localizedDescription }
    }

    private func deleteScans(at offsets: IndexSet) async {
        for i in offsets {
            let scan = scans[i]
            do { try await Repository.deleteScan(scan) } catch { self.error = error.localizedDescription; return }
        }
        scans.remove(atOffsets: offsets)
        await session.refreshEntitlement()
    }

    private func deleteJob() async {
        do { try await Repository.softDelete(jobId: jobId); dismiss() }
        catch { self.error = error.localizedDescription }
    }

    private func openInMaps(_ job: Job) {
        if let lat = job.latitude, let lng = job.longitude {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: lat, longitude: lng)))
            item.name = job.title
            item.openInMaps()
        } else if let q = job.addressSummary.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "maps://?q=\(q)") {
            UIApplication.shared.open(url)
        }
    }
}

struct ScanThumbnail: View {
    let scan: Scan
    @State private var url: URL?
    var body: some View {
        AsyncImage(url: url) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "cube.transparent").font(.title2).foregroundStyle(.secondary)
        }
        .frame(width: 56, height: 56)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            if let p = scan.thumbnailPath { url = try? await Repository.signedURL(bucket: "scans", path: p) }
        }
    }
}
