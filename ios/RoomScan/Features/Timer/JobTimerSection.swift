import SwiftUI

/// Start/stop a work timer on a job; shows total time and history.
struct JobTimerSection: View {
    @Environment(SessionStore.self) private var session
    let job: Job

    @State private var entries: [TimeEntry] = []
    @State private var now = Date()
    @State private var busy = false
    @State private var error: String?

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var running: TimeEntry? { entries.first { $0.isRunning && $0.userId == session.userId } }
    private var total: TimeInterval {
        entries.reduce(0) { $0 + (($1.endedAt ?? now).timeIntervalSince($1.startedAt)) }
    }

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading) {
                    Text(total.hms).font(.system(.title2, design: .monospaced).bold())
                    Text(running == nil ? "Total time" : "Running…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await toggle() }
                } label: {
                    Label(running == nil ? "Start" : "Stop", systemImage: running == nil ? "play.fill" : "stop.fill")
                        .frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .tint(running == nil ? .green : .red)
                .disabled(busy)
            }
            .onReceive(tick) { now = $0 }
            .task { await load() }
            ForEach(entries.prefix(5)) { e in
                HStack {
                    Text(e.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Spacer()
                    Text(((e.endedAt ?? now).timeIntervalSince(e.startedAt)).hms).monospacedDigit()
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        } header: { Text("Timer") }
    }

    private func load() async {
        do { entries = try await Repository.timeEntries(jobId: job.id) }
        catch { self.error = error.localizedDescription }
    }

    private func toggle() async {
        guard let userId = session.userId else { return }
        busy = true; defer { busy = false }
        do {
            if let r = running {
                let stopped = try await Repository.stopTimer(r)
                entries = entries.map { $0.id == stopped.id ? stopped : $0 }
            } else {
                let e = try await Repository.startTimer(jobId: job.id, orgId: job.orgId, userId: userId)
                entries.insert(e, at: 0)
            }
        } catch { self.error = error.localizedDescription }
    }
}
