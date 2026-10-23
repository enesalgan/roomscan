import SwiftUI

/// Landing screen: one big action — start a new measurement. Recent jobs underneath.
struct HomeView: View {
    @Environment(SessionStore.self) private var session

    @State private var recent: [Job] = []
    @State private var showQuickJob = false
    @State private var startJob: Job?        // job created from the quick sheet → push detail with scanner auto-started
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    bigButton
                    recentSection
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: JobRoute.self) { route in
                JobDetailView(jobId: route.id, autoStartScan: route.autoScan)
            }
            .sheet(isPresented: $showQuickJob) {
                QuickJobSheet { job in
                    recent.insert(job, at: 0)
                    path.append(JobRoute(id: job.id, autoScan: true))
                }
                .presentationDetents([.large])
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting).font(.title2.weight(.bold)).fontDesign(.rounded)
                Text(session.organization?.name ?? "").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            entitlementBadge
        }
        .padding(.top, 8)
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let who = session.profile?.fullName?.split(separator: " ").first.map(String.init) ?? ""
        let base = h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
        return who.isEmpty ? base : "\(base), \(who)"
    }

    @ViewBuilder private var entitlementBadge: some View {
        let e = session.entitlement
        if e.subscribed {
            Label("Pro", systemImage: "checkmark.seal.fill").font(.caption.bold()).foregroundStyle(.green)
        } else {
            Text("\(e.scansRemaining ?? 0) free scans").font(.caption.bold())
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
    }

    private var bigButton: some View {
        Button { showQuickJob = true } label: {
            VStack(spacing: 14) {
                ScanPulseIcon()
                    .frame(width: 170, height: 170)
                Text("New Measurement").font(.title3.weight(.semibold)).fontDesign(.rounded)
                Text("Name the job, confirm the address, scan the room.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 34)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var recentSection: some View {
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recent").font(.headline).fontDesign(.rounded)
                ForEach(recent.prefix(5)) { job in
                    NavigationLink(value: JobRoute(id: job.id, autoScan: false)) {
                        HStack(spacing: 12) {
                            Image(systemName: job.status.systemImage)
                                .font(.subheadline)
                                .foregroundStyle(job.status.color)
                                .frame(width: 34, height: 34)
                                .background(job.status.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.title).font(.subheadline.weight(.semibold))
                                Text(job.addressSummary.isEmpty ? job.updatedAt.formatted(date: .abbreviated, time: .shortened) : job.addressSummary)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func load() async {
        recent = (try? await Repository.jobs()) ?? []
        await session.refreshEntitlement()
    }
}

struct JobRoute: Hashable {
    let id: UUID
    let autoScan: Bool
}

/// Minimal "new job" sheet: name + address (auto from location) → Start scanning.
struct QuickJobSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    let onCreated: (Job) -> Void

    @State private var title = ""
    @State private var address = AddressFields()
    @State private var locating = true
    @State private var showAddressSearch = false
    @State private var showMore = false
    @State private var customerName = ""
    @State private var customerPhone = ""
    @State private var customerEmail = ""
    @State private var hasSchedule = false
    @State private var scheduledAt = Date()
    @State private var notes = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Job name (e.g. Smith kitchen)", text: $title)
                        .font(.title3.weight(.semibold))
                        .focused($titleFocused)
                        .submitLabel(.done)
                }

                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "location.fill").foregroundStyle(Color.accentColor).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            if locating {
                                HStack(spacing: 8) { ProgressView(); Text("Finding your location…").foregroundStyle(.secondary) }
                            } else if address.line1.isEmpty && address.city.isEmpty {
                                Text("No address yet").foregroundStyle(.secondary)
                            } else {
                                Text(address.line1).font(.body.weight(.medium))
                                Text([address.city, address.state, address.postalCode].filter { !$0.isEmpty }.joined(separator: " "))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    HStack {
                        Button { showAddressSearch = true } label: { Label("Change", systemImage: "magnifyingglass") }
                        Spacer()
                        Button { Task { await locate() } } label: { Label("Use my location", systemImage: "location") }
                    }
                    .font(.subheadline)
                } header: { Text("Address") }

                Section {
                    DisclosureGroup("More details", isExpanded: $showMore) {
                        TextField("Customer name", text: $customerName).textContentType(.name)
                        TextField("Phone", text: $customerPhone).keyboardType(.phonePad)
                        TextField("Email", text: $customerEmail).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        Toggle("Appointment", isOn: $hasSchedule)
                        if hasSchedule { DatePicker("When", selection: $scheduledAt) }
                        TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...4)
                    }
                }

                if let error { Text(error).foregroundStyle(.red).font(.footnote) }

                Section {
                    Button { Task { await create() } } label: {
                        HStack {
                            Spacer()
                            if saving { ProgressView() } else { Label("Start scanning", systemImage: "cube.transparent").font(.headline) }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("New Measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $showAddressSearch) { AddressSearchView { address = $0 } }
            .task { titleFocused = true; await locate() }
        }
    }

    private func locate() async {
        locating = true; defer { locating = false }
        if let a = try? await LocationService.shared.currentAddress() { address = a }
    }

    private func create() async {
        guard let userId = session.userId, let orgId = session.profile?.orgId else { error = "Not signed in"; return }
        saving = true; defer { saving = false }
        var job = Job(orgId: orgId, createdBy: userId, title: title.trimmingCharacters(in: .whitespaces))
        job.addressLine1 = address.line1.nilIfEmpty
        job.addressLine2 = address.line2.nilIfEmpty
        job.city = address.city.nilIfEmpty
        job.state = address.state.nilIfEmpty
        job.postalCode = address.postalCode.nilIfEmpty
        job.country = address.country.nilIfEmpty ?? "US"
        job.latitude = address.latitude
        job.longitude = address.longitude
        job.customerName = customerName.nilIfEmpty
        job.customerPhone = customerPhone.nilIfEmpty
        job.customerEmail = customerEmail.nilIfEmpty
        job.notes = notes.nilIfEmpty
        job.scheduledAt = hasSchedule ? scheduledAt : nil
        if hasSchedule { job.status = .scheduled }
        do {
            let saved = try await Repository.upsert(job)
            dismiss()
            onCreated(saved)
        } catch { self.error = error.localizedDescription }
    }
}


/// Isometric room being scanned: a laser plane sweeps up and the point cloud assembles into
/// floor + two walls, then the wireframe edges draw in. Loops every ~5 s.
struct ScanPulseIcon: View {
    private struct P3 { var x: Double; var y: Double; var z: Double }

    // deterministic point cloud on floor (y=0), back wall (z=1) and left wall (x=0)
    private static let cloud: [P3] = {
        var pts: [P3] = []
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double((seed >> 11) & 0xFFFFFF) / Double(0xFFFFFF) }
        for _ in 0..<110 { pts.append(P3(x: rnd(), y: 0, z: rnd())) }
        for _ in 0..<90  { pts.append(P3(x: rnd(), y: rnd() * 0.75, z: 1)) }
        for _ in 0..<90  { pts.append(P3(x: 0, y: rnd() * 0.75, z: rnd())) }
        return pts
    }()

    private static let edges: [(P3, P3)] = {
        let H = 0.75
        let a = P3(x: 0, y: 0, z: 0), b = P3(x: 1, y: 0, z: 0), c = P3(x: 1, y: 0, z: 1), d = P3(x: 0, y: 0, z: 1)
        let a2 = P3(x: 0, y: H, z: 0), c2 = P3(x: 1, y: H, z: 1), d2 = P3(x: 0, y: H, z: 1)
        return [(a, b), (b, c), (c, d), (d, a),            // floor
                (a, a2), (d, d2), (c, c2),                 // verticals
                (a2, d2), (d2, c2)]                        // wall tops
    }()

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let accent = Color.accentColor
                let loop = 5.2
                let p = (t.truncatingRemainder(dividingBy: loop)) / loop     // 0…1
                let yaw = 0.62 + sin(t * 0.35) * 0.12                          // gentle rotation

                // isometric projection
                let S = min(size.width, size.height) * 0.62
                let cx = size.width / 2, cy = size.height / 2 + S * 0.18
                func proj(_ q: P3) -> CGPoint {
                    let x = (q.x - 0.5) * cos(yaw) - (q.z - 0.5) * sin(yaw)
                    let z = (q.x - 0.5) * sin(yaw) + (q.z - 0.5) * cos(yaw)
                    return CGPoint(x: cx + x * S, y: cy + z * S * 0.5 - q.y * S * 0.9)
                }

                // timeline: 0–0.68 sweep up, 0.68–0.88 hold, 0.88–1 fade
                let sweep = min(p / 0.68, 1)
                let scanY = sweep * 0.75
                let fade = p > 0.88 ? 1 - (p - 0.88) / 0.12 : 1.0

                // ghost edges (always, faint)
                var ghost = Path()
                for (a, b) in Self.edges { ghost.move(to: proj(a)); ghost.addLine(to: proj(b)) }
                ctx.stroke(ghost, with: .color(accent.opacity(0.10 * fade)), lineWidth: 1)

                // point cloud below the scan plane
                var dots = Path(), fresh = Path()
                for q in Self.cloud where q.y <= scanY {
                    let s = proj(q)
                    let age = (scanY - q.y) / 0.08                      // 0 = just revealed
                    let r: CGFloat = age < 1 ? 2.2 : 1.3
                    let rect = CGRect(x: s.x - r, y: s.y - r, width: 2 * r, height: 2 * r)
                    if age < 1 { fresh.addEllipse(in: rect) } else { dots.addEllipse(in: rect) }
                }
                ctx.fill(dots, with: .color(accent.opacity(0.55 * fade)))
                ctx.fill(fresh, with: .color(accent.opacity(0.95 * fade)))

                // edges draw in as the plane passes
                var solid = Path()
                for (a, b) in Self.edges {
                    let lo = min(a.y, b.y), hi = max(a.y, b.y)
                    guard scanY >= lo else { continue }
                    let f = hi == lo ? 1 : min((scanY - lo) / (hi - lo), 1)
                    let (from, to) = a.y <= b.y ? (a, b) : (b, a)
                    let end = P3(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f, z: from.z + (to.z - from.z) * f)
                    solid.move(to: proj(from)); solid.addLine(to: proj(end))
                }
                ctx.stroke(solid, with: .color(accent.opacity(0.9 * fade)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

                // scan plane (parallelogram at scanY) with bright leading edge
                if sweep < 1 {
                    let y = scanY
                    let quad = [P3(x: 0, y: y, z: 0), P3(x: 1, y: y, z: 0), P3(x: 1, y: y, z: 1), P3(x: 0, y: y, z: 1)].map(proj)
                    var plane = Path()
                    plane.move(to: quad[0]); for q in quad.dropFirst() { plane.addLine(to: q) }; plane.closeSubpath()
                    ctx.fill(plane, with: .color(accent.opacity(0.10)))
                    ctx.stroke(plane, with: .color(accent.opacity(0.8)), lineWidth: 1)
                }
            }
        }
    }
}
