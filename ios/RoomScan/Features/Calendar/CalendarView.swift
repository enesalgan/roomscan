import SwiftUI

/// Appointments: pick a day, see scheduled jobs; upcoming list below.
struct CalendarView: View {
    @State private var selectedDay = Date()
    @State private var monthJobs: [Job] = []
    @State private var error: String?

    private var cal: Calendar { Calendar.current }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker("Day", selection: $selectedDay, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
                Section(selectedDay.formatted(date: .complete, time: .omitted)) {
                    let day = jobs(on: selectedDay)
                    if day.isEmpty {
                        Text("No appointments").foregroundStyle(.secondary)
                    }
                    ForEach(day) { job in
                        NavigationLink(value: job.id) { CalendarRow(job: job) }
                    }
                }
                Section("Upcoming this month") {
                    let upcoming = monthJobs.filter { ($0.scheduledAt ?? .distantPast) >= cal.startOfDay(for: Date()) }
                    if upcoming.isEmpty { Text("Nothing scheduled").foregroundStyle(.secondary) }
                    ForEach(upcoming) { job in
                        NavigationLink(value: job.id) { CalendarRow(job: job, showDate: true) }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Calendar")
            .navigationDestination(for: UUID.self) { JobDetailView(jobId: $0) }
            .task(id: monthKey) { await load() }
            .refreshable { await load() }
        }
    }

    private var monthKey: String { "\(cal.component(.year, from: selectedDay))-\(cal.component(.month, from: selectedDay))" }

    private func jobs(on day: Date) -> [Job] {
        monthJobs.filter { j in j.scheduledAt.map { cal.isDate($0, inSameDayAs: day) } ?? false }
    }

    private func load() async {
        guard let interval = cal.dateInterval(of: .month, for: selectedDay) else { return }
        do { monthJobs = try await Repository.scheduledJobs(from: interval.start, to: interval.end) }
        catch { self.error = error.localizedDescription }
    }
}

struct CalendarRow: View {
    let job: Job
    var showDate = false
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.headline)
                if let c = job.customerName { Text(c).font(.subheadline) }
                if !job.addressSummary.isEmpty { Text(job.addressSummary).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if let d = job.scheduledAt {
                VStack(alignment: .trailing) {
                    Text(d.formatted(date: .omitted, time: .shortened)).font(.subheadline.bold())
                    if showDate { Text(d.formatted(.dateTime.month(.abbreviated).day())).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
