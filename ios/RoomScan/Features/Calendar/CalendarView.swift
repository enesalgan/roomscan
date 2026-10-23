import SwiftUI

/// Appointments: month grid with dots on busy days, day agenda below, + to schedule a job.
struct CalendarView: View {
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start
    @State private var selectedDay = Date()
    @State private var jobs: [Job] = []          // scheduled jobs for the visible month (± a week)
    @State private var error: String?
    @State private var showNew = false

    private var cal: Calendar { Calendar.current }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    monthHeader
                    monthGrid
                    agenda
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                .padding(.horizontal, 16).padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { JobDetailView(jobId: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Today") { withAnimation { selectedDay = Date(); month = cal.dateInterval(of: .month, for: Date())!.start } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                }
            }
            .sheet(isPresented: $showNew) {
                JobEditView(job: nil, scheduledDefault: defaultAppointmentTime) { saved in
                    jobs.append(saved)
                }
            }
            .task(id: month) { await load() }
            .refreshable { await load() }
        }
    }

    // MARK: Month header

    private var monthHeader: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").font(.headline).frame(width: 36, height: 36) }
            Spacer()
            Text(month.formatted(.dateTime.month(.wide).year())).font(.title3.weight(.semibold)).fontDesign(.rounded)
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right").font(.headline).frame(width: 36, height: 36) }
        }
        .padding(.top, 8)
    }

    private func shift(_ n: Int) {
        withAnimation { month = cal.date(byAdding: .month, value: n, to: month)! }
    }

    // MARK: Grid

    private var weekdaySymbols: [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(s[first...] + s[..<first])
    }

    private var gridDays: [Date?] {
        let range = cal.range(of: .day, in: .month, for: month)!
        let firstWeekday = cal.component(.weekday, from: month)
        let lead = (firstWeekday - cal.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: lead)
        for d in range { cells.append(cal.date(byAdding: .day, value: d - 1, to: month)) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    private var monthGrid: some View {
        VStack(spacing: 6) {
            HStack {
                ForEach(weekdaySymbols, id: \.self) { s in
                    Text(s).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(gridDays.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 48)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if v.translation.width < -30 { shift(1) } else if v.translation.width > 30 { shift(-1) }
        })
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let isToday = cal.isDateInToday(day)
        let dayJobs = jobs(on: day)
        return Button { withAnimation(.snappy) { selectedDay = day } } label: {
            VStack(spacing: 4) {
                Text("\(cal.component(.day, from: day))")
                    .font(.subheadline.weight(isToday || isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? Color.white : (isToday ? Color.accentColor : .primary))
                HStack(spacing: 3) {
                    ForEach(dayJobs.prefix(3)) { j in
                        Circle().fill(isSelected ? Color.white : j.status.color).frame(width: 5, height: 5)
                    }
                    if dayJobs.isEmpty { Circle().fill(.clear).frame(width: 5, height: 5) }
                }
            }
            .frame(maxWidth: .infinity).frame(height: 48)
            .background(isSelected ? Color.accentColor : (isToday ? Color.accentColor.opacity(0.12) : .clear), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: Agenda

    private var agenda: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(selectedDay.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.headline).fontDesign(.rounded)
                Spacer()
                let n = jobs(on: selectedDay).count
                Text(n == 0 ? String(localized: "Free") : n == 1 ? String(localized: "1 appointment") : String(localized: "\(n) appointments")).font(.caption).foregroundStyle(.secondary)
            }
            let day = jobs(on: selectedDay)
            if day.isEmpty {
                HStack {
                    Image(systemName: "calendar.badge.plus").foregroundStyle(.secondary)
                    Text("Nothing scheduled.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Add") { showNew = true }.font(.subheadline.weight(.semibold))
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            ForEach(day) { job in
                NavigationLink(value: job.id) { AppointmentRow(job: job) }.buttonStyle(.plain)
            }

            let upcoming = jobs.filter { ($0.scheduledAt ?? .distantPast) > cal.startOfDay(for: selectedDay).addingTimeInterval(86400) }
                .sorted { ($0.scheduledAt ?? .distantPast) < ($1.scheduledAt ?? .distantPast) }
            if !upcoming.isEmpty {
                Text("Later this month").font(.headline).fontDesign(.rounded).padding(.top, 8)
                ForEach(upcoming.prefix(8)) { job in
                    NavigationLink(value: job.id) { AppointmentRow(job: job, showDate: true) }.buttonStyle(.plain)
                }
            }
        }
    }

    private func jobs(on day: Date) -> [Job] {
        jobs.filter { j in j.scheduledAt.map { cal.isDate($0, inSameDayAs: day) } ?? false }
            .sorted { ($0.scheduledAt ?? .distantPast) < ($1.scheduledAt ?? .distantPast) }
    }

    private var defaultAppointmentTime: Date {
        var c = cal.dateComponents([.year, .month, .day], from: selectedDay)
        c.hour = 10; c.minute = 0
        return cal.date(from: c) ?? selectedDay
    }

    private func load() async {
        guard let interval = cal.dateInterval(of: .month, for: month) else { return }
        do {
            jobs = try await Repository.scheduledJobs(from: interval.start.addingTimeInterval(-7 * 86400), to: interval.end.addingTimeInterval(7 * 86400))
        } catch { self.error = error.localizedDescription }
    }
}

struct AppointmentRow: View {
    let job: Job
    var showDate = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                if let d = job.scheduledAt {
                    if showDate {
                        Text(d.formatted(.dateTime.day())).font(.title3.weight(.bold)).fontDesign(.rounded)
                        Text(d.formatted(.dateTime.month(.abbreviated))).font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text(d.formatted(.dateTime.hour().minute())).font(.subheadline.weight(.bold)).monospacedDigit()
                    }
                }
            }
            .frame(width: 56)
            .padding(.vertical, 6)
            .background(job.status.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(job.status.color)

            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let c = job.customerName, !c.isEmpty { Text(c).font(.caption).foregroundStyle(.secondary) }
                if !job.addressSummary.isEmpty {
                    Label(job.addressSummary, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if showDate, let d = job.scheduledAt {
                Text(d.formatted(.dateTime.hour().minute())).font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
