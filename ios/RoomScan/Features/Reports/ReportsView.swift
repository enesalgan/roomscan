import SwiftUI
import Charts

/// Reports: jobs & value by period, completion, status breakdown, 6-month trend.
struct ReportsView: View {
    @Environment(SessionStore.self) private var session

    enum Period: String, CaseIterable, Identifiable {
        case week = "This week", month = "This month", year = "This year", all = "All time"
        var id: String { rawValue }
    }

    @State private var jobs: [Job] = []
    @State private var scanCount = 0
    @State private var period: Period = .month
    @State private var error: String?

    private var cal: Calendar { Calendar.current }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Period", selection: $period) {
                        ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    kpiGrid
                    trendCard
                    statusCard
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                .padding(.horizontal, 16).padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Reports")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .refreshable { await load() }
        }
    }

    // MARK: Data

    private var periodStart: Date? {
        switch period {
        case .week: cal.dateInterval(of: .weekOfYear, for: Date())?.start
        case .month: cal.dateInterval(of: .month, for: Date())?.start
        case .year: cal.dateInterval(of: .year, for: Date())?.start
        case .all: nil
        }
    }

    private var inPeriod: [Job] {
        guard let start = periodStart else { return jobs }
        return jobs.filter { $0.createdAt >= start }
    }
    private var completedInPeriod: [Job] {
        guard let start = periodStart else { return jobs.filter { $0.status == .won } }
        return jobs.filter { $0.status == .won && $0.updatedAt >= start }
    }
    private var openJobs: [Job] { jobs.filter { !$0.status.isClosed } }

    private func money(_ v: Double) -> String {
        v.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    // MARK: KPIs

    private var kpiGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            kpi("New jobs", "\(inPeriod.count)", "plus.circle.fill", .blue)
            kpi("Completed", "\(completedInPeriod.count)", "checkmark.seal.fill", .green)
            kpi("Completed value", money(completedInPeriod.compactMap { $0.estimateAmount }.reduce(0, +)), "dollarsign.circle.fill", .green)
            kpi("Pipeline value", money(openJobs.compactMap { $0.estimateAmount }.reduce(0, +)), "chart.line.uptrend.xyaxis", .orange)
            kpi("Open jobs", "\(openJobs.count)", "tray.full.fill", .indigo)
            kpi("Scans", "\(scanCount)", "cube.transparent", .teal)
        }
    }

    private func kpi(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            Text(value).font(.title2.weight(.bold)).fontDesign(.rounded).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Trend (last 6 months)

    private struct MonthPoint: Identifiable {
        let id: Date
        let label: String
        let created: Int
        let completed: Int
    }

    private var trend: [MonthPoint] {
        (0..<6).reversed().compactMap { back -> MonthPoint? in
            guard let m = cal.date(byAdding: .month, value: -back, to: cal.dateInterval(of: .month, for: Date())!.start),
                  let iv = cal.dateInterval(of: .month, for: m) else { return nil }
            let created = jobs.filter { iv.contains($0.createdAt) }.count
            let completed = jobs.filter { $0.status == .won && iv.contains($0.updatedAt) }.count
            return MonthPoint(id: m, label: m.formatted(.dateTime.month(.abbreviated)), created: created, completed: completed)
        }
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last 6 months").font(.headline).fontDesign(.rounded)
            Chart(trend) { p in
                BarMark(x: .value("Month", p.label), y: .value("Jobs", p.created))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                    .cornerRadius(4)
                LineMark(x: .value("Month", p.label), y: .value("Completed", p.completed))
                    .foregroundStyle(.green)
                    .symbol(Circle())
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 170)
            HStack(spacing: 14) {
                legend(Color.accentColor, "New jobs")
                legend(.green, "Completed")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) { Circle().fill(c).frame(width: 8, height: 8); Text(t) }
    }

    // MARK: Status breakdown

    private var statusCard: some View {
        let counts = Dictionary(grouping: jobs.filter { $0.status != .archived }, by: { $0.status }).mapValues { $0.count }
        let total = max(counts.values.reduce(0, +), 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("By status").font(.headline).fontDesign(.rounded)
            ForEach(JobStatus.allCases.filter { $0 != .archived }) { s in
                let n = counts[s] ?? 0
                HStack(spacing: 10) {
                    Image(systemName: s.systemImage).foregroundStyle(s.color).frame(width: 22)
                    Text(s.title).font(.subheadline)
                    Spacer()
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(s.color.opacity(0.15))
                            Capsule().fill(s.color).frame(width: g.size.width * CGFloat(n) / CGFloat(total))
                        }
                    }
                    .frame(width: 110, height: 8)
                    Text("\(n)").font(.subheadline.weight(.semibold)).monospacedDigit().frame(width: 28, alignment: .trailing)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func load() async {
        do {
            jobs = try await Repository.jobs(includeArchived: true)
            scanCount = (try? await Repository.scanCount()) ?? 0
        } catch { self.error = error.localizedDescription }
    }
}
