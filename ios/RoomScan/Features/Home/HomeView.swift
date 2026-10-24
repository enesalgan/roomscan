import SwiftUI

/// Landing screen: one big action — start a new measurement. Recent jobs underneath.
struct HomeView: View {
    @Environment(SessionStore.self) private var session

    @State private var recent: [Job] = []
    @State private var starting = false
    @State private var showPaywall = false
    @State private var showNewMeasurement = false
    @State private var startError: String?
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
                JobDetailView(jobId: route.id, autoStartScan: route.autoScan, autoRoomName: route.roomName)
            }
            .alert("Couldn't start", isPresented: Binding(get: { startError != nil }, set: { if !$0 { startError = nil } })) {
                Button("OK") {}
            } message: { Text(startError ?? "") }
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .sheet(isPresented: $showNewMeasurement) {
                NewMeasurementSheet { address, room in Task { await startMeasurement(address: address, roomName: room) } }
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
        let base = h < 12 ? String(localized: "Good morning") : h < 18 ? String(localized: "Good afternoon") : String(localized: "Good evening")
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
        Button {
            if session.entitlement.canScan { showNewMeasurement = true } else { showPaywall = true }
        } label: {
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(red: 0.055, green: 0.102, blue: 0.184),
                                        Color(red: 0.039, green: 0.075, blue: 0.141),
                                        Color(red: 0.043, green: 0.102, blue: 0.227)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RoomHeroAnimation()
                    .padding(.bottom, 64)
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        Text("New Measurement").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                    }
                    Text("Confirm the address, pick the room, scan.")
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55))
                }
                .padding(.bottom, 22)
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
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
        LocationService.shared.prewarm()   // ask for permission + cache a fix so the first scan gets its address instantly
    }

    /// Tap → confirm address + pick the room → job is created (named after the address) → scanner opens.
    private func startMeasurement(address a: AddressFields?, roomName: String) async {
        guard !starting, let userId = session.userId, let orgId = session.profile?.orgId else { return }
        starting = true; defer { starting = false }

        var job = Job(orgId: orgId, createdBy: userId, title: String(localized: "New measurement"))
        if let a {
            job.addressLine1 = a.line1.nilIfEmpty; job.addressLine2 = a.line2.nilIfEmpty
            job.city = a.city.nilIfEmpty; job.state = a.state.nilIfEmpty; job.postalCode = a.postalCode.nilIfEmpty
            job.country = a.country.nilIfEmpty ?? "US"; job.latitude = a.latitude; job.longitude = a.longitude
            if let t = [a.line1, a.city].compactMap({ $0.nilIfEmpty }).first { job.title = t }
        }
        do {
            let saved = try await Repository.upsert(job)
            recent.insert(saved, at: 0)
            path.append(JobRoute(id: saved.id, autoScan: true, roomName: roomName))
        } catch { startError = error.localizedDescription }
    }
}

struct JobRoute: Hashable {
    let id: UUID
    let autoScan: Bool
    var roomName: String? = nil
}

/// Hero: an isometric room draws itself as a hairline, a light sweep reveals its surfaces,
/// then a window, a door and two dimensions appear. 9 s loop, eased, monochrome.
struct RoomHeroAnimation: View {
    private struct P3 { var x: Double; var y: Double; var z: Double }
    private static let H = 0.62

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas(rendersAsynchronously: true) { ctx, size in
                draw(&ctx, size: size, t: t)
            }
        }
    }

    private func ease(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    private func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let loop = 9.0
        let p = t.truncatingRemainder(dividingBy: loop) / loop
        let yaw = sin(t * 0.16) * 0.05
        let S = min(size.width * 0.27, size.height * 0.42)
        let cx = size.width / 2, cy = size.height / 2 + 6
        let ink = Color.white

        func proj(_ q: P3) -> CGPoint {
            let x0 = q.x - 0.5, z0 = q.z - 0.5
            let x = x0 * cos(yaw) - z0 * sin(yaw), z = x0 * sin(yaw) + z0 * cos(yaw)
            return CGPoint(x: cx + (x - z) * 0.866 * S, y: cy + (x + z) * 0.5 * S - q.y * S)
        }
        let H = Self.H
        let A = proj(P3(x: 0, y: 0, z: 0)), B = proj(P3(x: 1, y: 0, z: 0)), C = proj(P3(x: 1, y: 0, z: 1)), D = proj(P3(x: 0, y: 0, z: 1))
        let A2 = proj(P3(x: 0, y: H, z: 0)), C2 = proj(P3(x: 1, y: H, z: 1)), D2 = proj(P3(x: 0, y: H, z: 1))
        let seq: [[CGPoint]] = [[A, B, C, D, A, A2, D2, C2, C], [D, D2]]

        let draw1 = ease(clamp(p / 0.2))
        let fade = p > 0.93 ? 1 - (p - 0.93) / 0.07 : 1.0

        // faint full outline
        ctx.stroke(polyline(seq, fraction: 1), with: .color(ink.opacity(0.10 * fade)), lineWidth: 0.8)

        // light sweep across the three faces
        let sw = clamp((p - 0.22) / 0.42), se = ease(sw)
        let all = [A, B, C, D, A2, C2, D2]
        let minX = all.map(\.x).min()!, maxX = all.map(\.x).max()!
        let sx = minX + (maxX - minX + 60) * se - 30
        let faces: [[CGPoint]] = [[A, B, C, D], [A, A2, D2, D], [D, D2, C2, C]]
        for (i, f) in faces.enumerated() {
            var face = Path(); face.move(to: f[0]); for q in f.dropFirst() { face.addLine(to: q) }; face.closeSubpath()
            var l = ctx
            l.clip(to: face)
            let strong = i == 0 ? 0.09 : 0.06, mid = i == 0 ? 0.05 : 0.035
            let band = CGRect(x: minX - 80, y: 0, width: sx - (minX - 80), height: size.height)
            l.fill(Path(band), with: .linearGradient(
                Gradient(stops: [.init(color: ink.opacity(0), location: 0), .init(color: ink.opacity(mid), location: 0.75), .init(color: ink.opacity(strong), location: 1)]),
                startPoint: CGPoint(x: sx - 70, y: 0), endPoint: CGPoint(x: sx, y: 0)))
            let washed = CGRect(x: minX - 80, y: 0, width: max(0, sx - 70 - (minX - 80)), height: size.height)
            l.fill(Path(washed), with: .color(ink.opacity((i == 0 ? 0.05 : 0.03) * fade)))
        }

        // scan line
        if sw > 0 && sw < 1 {
            let y0 = all.map(\.y).min()! - 6, y1 = all.map(\.y).max()! + 6
            var line = Path(); line.move(to: CGPoint(x: sx, y: y0)); line.addLine(to: CGPoint(x: sx, y: y1))
            ctx.stroke(line, with: .color(ink.opacity(0.06)), lineWidth: 10)
            ctx.stroke(line, with: .linearGradient(
                Gradient(stops: [.init(color: ink.opacity(0), location: 0), .init(color: ink.opacity(0.7), location: 0.5), .init(color: ink.opacity(0), location: 1)]),
                startPoint: CGPoint(x: sx, y: y0), endPoint: CGPoint(x: sx, y: y1)), lineWidth: 1)
        }

        // outline drawing itself
        ctx.stroke(polyline(seq, fraction: draw1), with: .color(ink.opacity(0.85 * fade)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))

        // details: window, door, dimensions
        let det = ease(clamp((p - 0.58) / 0.14))
        guard det > 0 else { return }
        let a = det * fade

        var win = Path()
        let w = [P3(x: 0.32, y: 0.24, z: 1), P3(x: 0.7, y: 0.24, z: 1), P3(x: 0.7, y: 0.5, z: 1), P3(x: 0.32, y: 0.5, z: 1)].map(proj)
        win.move(to: w[0]); for q in w.dropFirst() { win.addLine(to: q) }; win.closeSubpath()
        win.move(to: proj(P3(x: 0.51, y: 0.24, z: 1))); win.addLine(to: proj(P3(x: 0.51, y: 0.5, z: 1)))
        let door = [P3(x: 0, y: 0, z: 0.55), P3(x: 0, y: 0.5, z: 0.55), P3(x: 0, y: 0.5, z: 0.85), P3(x: 0, y: 0, z: 0.85)].map(proj)
        win.move(to: door[0]); for q in door.dropFirst() { win.addLine(to: q) }
        ctx.stroke(win, with: .color(ink.opacity(0.6 * a)), lineWidth: 0.9)

        var arc = Path()
        for k in 0...14 {
            let ang = Double(k) / 14 * .pi / 2
            let pt = proj(P3(x: 0.3 * sin(ang), y: 0, z: 0.55 + 0.3 * (1 - cos(ang))))
            if k == 0 { arc.move(to: pt) } else { arc.addLine(to: pt) }
        }
        ctx.stroke(arc, with: .color(ink.opacity(0.35 * a)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))

        // width dimension along the front edge (B→C)
        let off = 14.0
        let n = CGPoint(x: C.y - B.y, y: -(C.x - B.x))
        let L = hypot(n.x, n.y)
        let nx = n.x / L * off, ny = n.y / L * off
        let b1 = CGPoint(x: B.x - nx, y: B.y - ny), c1 = CGPoint(x: C.x - nx, y: C.y - ny)
        var dim = Path()
        dim.move(to: b1); dim.addLine(to: c1)
        dim.move(to: CGPoint(x: B.x - nx * 0.3, y: B.y - ny * 0.3)); dim.addLine(to: CGPoint(x: b1.x - nx * 0.25, y: b1.y - ny * 0.25))
        dim.move(to: CGPoint(x: C.x - nx * 0.3, y: C.y - ny * 0.3)); dim.addLine(to: CGPoint(x: c1.x - nx * 0.25, y: c1.y - ny * 0.25))
        // height dimension on the left edge (A→A2)
        let h1 = CGPoint(x: A.x - 16, y: A.y), h2 = CGPoint(x: A2.x - 16, y: A2.y)
        dim.move(to: h1); dim.addLine(to: h2)
        dim.move(to: CGPoint(x: h1.x - 3, y: h1.y)); dim.addLine(to: CGPoint(x: h1.x + 3, y: h1.y))
        dim.move(to: CGPoint(x: h2.x - 3, y: h2.y)); dim.addLine(to: CGPoint(x: h2.x + 3, y: h2.y))
        ctx.stroke(dim, with: .color(ink.opacity(0.45 * a)), lineWidth: 0.8)

        let font = Font.system(size: 10.5, weight: .semibold)
        let mid = CGPoint(x: (b1.x + c1.x) / 2 - nx * 0.9, y: (b1.y + c1.y) / 2 - ny * 0.9)
        var angle = atan2(C.y - B.y, C.x - B.x)
        if angle > .pi / 2 { angle -= .pi } else if angle < -.pi / 2 { angle += .pi }
        ctx.drawLayer { l in
            l.translateBy(x: mid.x, y: mid.y); l.rotate(by: .radians(angle))
            l.draw(Text("14' 6\"").font(font).foregroundStyle(ink.opacity(0.85 * a)), at: .zero, anchor: .center)
        }
        ctx.drawLayer { l in
            l.translateBy(x: h1.x - 9, y: (h1.y + h2.y) / 2); l.rotate(by: .radians(-.pi / 2))
            l.draw(Text("8' 11\"").font(font).foregroundStyle(ink.opacity(0.85 * a)), at: .zero, anchor: .center)
        }
    }

    /// Polyline sequences drawn up to a fraction of their total length ("draws itself").
    private func polyline(_ seqs: [[CGPoint]], fraction: Double) -> Path {
        var segs: [(CGPoint, CGPoint, Double)] = []
        var total = 0.0
        for seq in seqs {
            for i in 1..<seq.count {
                let l = hypot(seq[i].x - seq[i - 1].x, seq[i].y - seq[i - 1].y)
                segs.append((seq[i - 1], seq[i], l)); total += l
            }
        }
        var budget = fraction * total
        var path = Path()
        for (a, b, l) in segs {
            if budget <= 0 { break }
            let f = min(1, budget / l)
            path.move(to: a)
            path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            budget -= l
        }
        return path
    }
}
