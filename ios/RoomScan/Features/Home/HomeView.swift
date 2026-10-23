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


/// Animated LiDAR-style icon: expanding rings, orbiting point cloud and a sweeping scan arc around the cube.
struct ScanPulseIcon: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let R = min(size.width, size.height) / 2
                let accent = Color.accentColor

                // expanding rings (3, staggered)
                for k in 0..<3 {
                    let phase = (t / 2.4 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                    let r = R * (0.35 + 0.65 * phase)
                    let alpha = (1 - phase) * 0.35
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(accent.opacity(alpha)), lineWidth: 1.2)
                }

                // sweeping arc
                let sweep = (t * 0.9).truncatingRemainder(dividingBy: 2 * .pi)
                var arc = Path()
                arc.addArc(center: c, radius: R * 0.78, startAngle: .radians(sweep - 0.9), endAngle: .radians(sweep), clockwise: false)
                ctx.stroke(arc, with: .linearGradient(Gradient(colors: [accent.opacity(0), accent.opacity(0.9)]),
                                                      startPoint: CGPoint(x: c.x - R, y: c.y), endPoint: CGPoint(x: c.x + R, y: c.y)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))

                // point cloud: 28 dots drifting on orbits
                var dots = Path()
                for i in 0..<28 {
                    let seed = Double(i) * 1.618
                    let orbit = R * (0.42 + 0.36 * (sin(seed * 3.1) * 0.5 + 0.5))
                    let speed = 0.25 + (seed.truncatingRemainder(dividingBy: 1)) * 0.35
                    let a = seed * 2 + t * speed
                    let wob = sin(t * 1.7 + seed) * 3
                    let p = CGPoint(x: c.x + cos(a) * (orbit + wob), y: c.y + sin(a) * (orbit + wob))
                    let dr: CGFloat = 1.2 + CGFloat(sin(t * 2 + seed) * 0.5 + 0.5) * 1.3
                    dots.addEllipse(in: CGRect(x: p.x - dr, y: p.y - dr, width: 2 * dr, height: 2 * dr))
                }
                ctx.fill(dots, with: .color(accent.opacity(0.7)))

                // core disc
                let core = R * 0.36
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: 2 * core, height: 2 * core)), with: .color(accent.opacity(0.14)))
            }
            .overlay {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .scaleEffect(1 + 0.04 * sin(t * 2))
            }
        }
    }
}
