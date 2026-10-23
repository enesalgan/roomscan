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
            ScrollView {
                LazyVStack(spacing: 8, pinnedViews: []) {
                    statusChips
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                    if filtered.isEmpty && !loading {
                        ContentUnavailableView(search.isEmpty ? "No jobs yet" : "No matches", systemImage: "list.clipboard",
                                               description: Text(search.isEmpty ? "Tap + to create your first job." : "Try a different search."))
                            .padding(.top, 40)
                    }
                    ForEach(filtered) { job in
                        NavigationLink(value: job.id) { JobCard(job: job) }
                            .buttonStyle(.plain)
                            .opacity(filter == nil && job.status.isClosed ? 0.55 : 1)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Jobs")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { JobDetailView(jobId: $0) }
            .searchable(text: $search, prompt: "Customer, title or address")
            .refreshable { await load() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { entitlementBadge }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                }
            }
            .sheet(isPresented: $showNew) {
                JobEditView(job: nil) { saved in jobs.insert(saved, at: 0) }
            }
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .task { await load() }
        }
    }

    // MARK: Filters

    private var counts: [JobStatus: Int] {
        Dictionary(grouping: jobs, by: { $0.status }).mapValues { $0.count }
    }

    private var statusChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", icon: "square.grid.2x2", count: jobs.filter { $0.status != .archived }.count, color: .accentColor, selected: filter == nil) { filter = nil }
                ForEach(JobStatus.allCases.filter { $0 != .archived || filter == .archived || (counts[.archived] ?? 0) > 0 }) { s in
                    chip(title: s.title, icon: s.systemImage, count: counts[s] ?? 0, color: s.color, selected: filter == s) {
                        filter = (filter == s) ? nil : s
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func chip(title: String, icon: String, count: Int, color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(title).font(.caption.weight(.semibold))
                if count > 0 {
                    Text("\(count)").font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background((selected ? Color.white.opacity(0.25) : color.opacity(0.15)), in: Capsule())
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(selected ? color : Color(.secondarySystemGroupedBackground), in: Capsule())
            .foregroundStyle(selected ? Color.white : color)
        }
        .buttonStyle(.plain)
    }

    private var filtered: [Job] {
        let list = jobs.filter { job in
            (filter == nil ? job.status != .archived : job.status == filter) &&
            (search.isEmpty ||
             job.title.localizedCaseInsensitiveContains(search) ||
             (job.customerName ?? "").localizedCaseInsensitiveContains(search) ||
             job.addressSummary.localizedCaseInsensitiveContains(search))
        }
        // active work first, completed/lost at the bottom
        guard filter == nil else { return list }
        return list.sorted { a, b in
            if a.status.isClosed != b.status.isClosed { return !a.status.isClosed }
            return a.updatedAt > b.updatedAt
        }
    }

    @ViewBuilder private var entitlementBadge: some View {
        let e = session.entitlement
        Button { if !e.subscribed { showPaywall = true } } label: {
            if e.subscribed {
                Label("Pro", systemImage: "checkmark.seal.fill").font(.caption.bold()).foregroundStyle(.green)
            } else {
                Label("\(e.scansRemaining ?? 0) free", systemImage: "cube.transparent")
                    .font(.caption.bold())
                    .foregroundStyle((e.scansRemaining ?? 0) > 0 ? Color.accentColor : .red)
            }
        }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            jobs = try await Repository.jobs(includeArchived: true)
            await session.refreshEntitlement()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Card

struct JobCard: View {
    let job: Job

    private var subtitle: String {
        [job.customerName, job.addressSummary.nilIfEmpty].compactMap { $0?.nilIfEmpty }.joined(separator: "  ·  ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(job.title).font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                Text(job.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                StatusChip(status: job.status)
            }
            if !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            if job.scheduledAt != nil || job.estimateAmount != nil {
                HStack(spacing: 12) {
                    if let d = job.scheduledAt {
                        Label(d.formatted(.dateTime.month(.abbreviated).day().hour().minute()), systemImage: "calendar")
                            .foregroundStyle(d < Date() ? Color.secondary : Color.purple)
                    }
                    if let e = job.estimateAmount {
                        Label(e.formatted(.currency(code: job.estimateCurrency).precision(.fractionLength(0))), systemImage: "dollarsign.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption.weight(.medium))
            }
        }
        .padding(.vertical, 12).padding(.leading, 16).padding(.trailing, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(job.status.color).frame(width: 3).padding(.vertical, 12).padding(.leading, 6)
        }
    }
}

struct StatusChip: View {
    let status: JobStatus
    var compact = false
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.systemImage)
            if !compact { Text(status.title) }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, compact ? 6 : 9).padding(.vertical, 5)
        .background(status.color.opacity(0.14), in: Capsule())
        .foregroundStyle(status.color)
    }
}
