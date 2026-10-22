import SwiftUI

struct JobsListView: View {
    @Environment(SessionStore.self) private var session

    @State private var jobs: [Job] = []
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    @State private var filter: JobStatus?
    @State private var showNew = false
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }

                ForEach(filtered) { job in
                    NavigationLink(value: job.id) { JobRow(job: job) }
                }
            }
            .listStyle(.plain)
            .overlay {
                if jobs.isEmpty && !loading {
                    ContentUnavailableView("No jobs yet", systemImage: "list.clipboard",
                                           description: Text("Tap + to create your first job."))
                }
            }
            .navigationTitle("Jobs")
            .navigationDestination(for: UUID.self) { JobDetailView(jobId: $0) }
            .searchable(text: $search, prompt: "Customer, title or address")
            .refreshable { await load() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { entitlementBadge }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Status", selection: $filter) {
                            Text("All").tag(JobStatus?.none)
                            ForEach(JobStatus.allCases) { Label($0.title, systemImage: $0.systemImage).tag(JobStatus?.some($0)) }
                        }
                    } label: { Image(systemName: filter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showNew) {
                JobEditView(job: nil) { saved in
                    jobs.insert(saved, at: 0)
                }
            }
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .task { await load() }
        }
    }

    private var filtered: [Job] {
        jobs.filter { job in
            (filter == nil || job.status == filter) &&
            (search.isEmpty ||
             job.title.localizedCaseInsensitiveContains(search) ||
             (job.customerName ?? "").localizedCaseInsensitiveContains(search) ||
             job.addressSummary.localizedCaseInsensitiveContains(search))
        }
    }

    @ViewBuilder private var entitlementBadge: some View {
        let e = session.entitlement
        Button { if !e.subscribed { showPaywall = true } } label: {
            if e.subscribed {
                Label("Pro", systemImage: "checkmark.seal.fill").font(.caption.bold()).foregroundStyle(.green)
            } else {
                Label("\(e.scansRemaining ?? 0) free scans", systemImage: "cube.transparent")
                    .font(.caption.bold())
                    .foregroundStyle((e.scansRemaining ?? 0) > 0 ? Color.accentColor : .red)
            }
        }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            jobs = try await Repository.jobs(includeArchived: filter == .archived)
            await session.refreshEntitlement()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct JobRow: View {
    let job: Job
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.title).font(.headline)
                Spacer()
                StatusChip(status: job.status)
            }
            if let c = job.customerName, !c.isEmpty { Text(c).font(.subheadline) }
            if !job.addressSummary.isEmpty {
                Text(job.addressSummary).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            if let d = job.scheduledAt {
                Label(d.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatusChip: View {
    let status: JobStatus
    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
    private var color: Color {
        switch status {
        case .new: .blue
        case .scheduled: .purple
        case .measured: .teal
        case .designing: .orange
        case .quoted: .indigo
        case .won: .green
        case .lost: .red
        case .archived: .gray
        }
    }
}
