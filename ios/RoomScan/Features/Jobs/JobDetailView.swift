import SwiftUI
import MapKit
import RoomPlan

struct JobDetailView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    let jobId: UUID

    @State private var job: Job?
    @State private var scans: [Scan] = []
    @State private var photos: [Photo] = []
    @State private var error: String?
    @State private var showEdit = false
    @State private var showScanner = false
    @State private var showPaywall = false
    @State private var scanToPreview: Scan?
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let job {
                List {
                    headerSection(job)
                    customerSection(job)
                    scansSection(job)
                    PhotosSection(job: job, photos: $photos)
                    JobTimerSection(job: job)
                    if let n = job.notes, !n.isEmpty { Section("Notes") { Text(n) } }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                .navigationTitle(job.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
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
                .fullScreenCover(isPresented: $showScanner) {
                    ScanSessionView(job: job) { saved in
                        scans.insert(saved, at: 0)
                        Task { await session.refreshEntitlement() }
                    }
                }
                .sheet(isPresented: $showPaywall) { PaywallView() }
                .sheet(item: $scanToPreview) { ScanPreviewView(scan: $0) }
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
            if !job.addressSummary.isEmpty {
                Button {
                    openInMaps(job)
                } label: {
                    Label { Text(job.addressSummary).foregroundStyle(.primary) } icon: { Image(systemName: "map") }
                }
            }
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

    @ViewBuilder private func scansSection(_ job: Job) -> some View {
        Section {
            Button {
                startScan()
            } label: {
                Label("Scan a room with LiDAR", systemImage: "cube.transparent")
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
        showScanner = true
    }

    private func load() async {
        do {
            async let j = Repository.job(id: jobId)
            async let s = Repository.scans(jobId: jobId)
            async let p = Repository.photos(jobId: jobId)
            job = try await j; scans = try await s; photos = try await p
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
