import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(StoreService.self) private var store
    @Environment(AppLanguage.self) private var language

    @State private var members: [Profile] = []
    @State private var invites: [OrgInvite] = []
    @State private var showPaywall = false
    @State private var showNewInvite = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if session.isDemo {
                    Section {
                        Label("Demo mode — data is only on this device", systemImage: "testtube.2").foregroundStyle(.orange)
                        Button("Reset demo data", role: .destructive) {
                            DemoStore.shared.reset(); Task { await session.refreshEntitlement() }
                        }
                    }
                }
                Section("Account") {
                    LabeledContent("Name", value: session.profile?.displayName ?? "—")
                    LabeledContent("Email", value: session.profile?.email ?? "—")
                    LabeledContent("Role", value: session.profile?.role.rawValue.capitalized ?? "—")
                }

                Section("Organization") {
                    LabeledContent("Name", value: session.organization?.name ?? "—")
                    LabeledContent("Type", value: String(localized: session.organization?.type == .company ? "Company / Branch" : "Individual"))
                }

                Section("Language") {
                    Picker("Language", selection: Binding(get: { language.code }, set: { language.code = $0 })) {
                        ForEach(AppLanguage.options) { o in Text("\(o.flag)  \(o.name)").tag(o.code) }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section("Plan") {
                    if session.entitlement.subscribed {
                        Label("RoomScan Pro — unlimited scans", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        LabeledContent("Free scans remaining", value: "\(session.entitlement.scansRemaining ?? 0)")
                        Button { showPaywall = true } label: { Label("Upgrade to Pro", systemImage: "sparkles") }
                    }
                    LabeledContent("Scans used", value: "\(session.entitlement.scansUsed)")
                    Button("Restore purchases") { Task { await store.restore(); await session.refreshEntitlement() } }
                }

                if session.profile?.isAdmin == true {
                    Section {
                        ForEach(members) { m in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(m.displayName)
                                    Text(m.email ?? "").font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(m.role.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: { Text("Members (\(members.count))") }

                    Section {
                        Button { showNewInvite = true } label: { Label("New invite code", systemImage: "person.badge.plus") }
                        ForEach(invites) { inv in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(inv.code).font(.system(.body, design: .monospaced).bold())
                                    Text("\(inv.role.rawValue.capitalized)\(inv.email.map { " · \($0)" } ?? "") · expires \(inv.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                ShareLink(item: "Join \(session.organization?.name ?? "our team") on RoomScan with invite code \(inv.code)") {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                        }
                        .onDelete { idx in Task { await deleteInvites(idx) } }
                    } header: { Text("Invites") } footer: {
                        Text("Staff sign up with \"Join with code\" and land in your organization. Scans count against the organization's plan.")
                    }
                }

                if let error { Text(error).foregroundStyle(.red).font(.footnote) }

                Section {
                    Button(session.isDemo ? String(localized: "Exit demo") : String(localized: "Sign out"), role: .destructive) { Task { await session.signOut() } }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                }
            }
            .navigationTitle("Settings")
            .task { await load() }
            .refreshable { await load() }
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .sheet(isPresented: $showNewInvite) {
                NewInviteSheet { inv in invites.insert(inv, at: 0) }
            }
        }
    }

    private func load() async {
        await session.refreshEntitlement()
        guard session.profile?.isAdmin == true else { return }
        do {
            async let m = Repository.members()
            async let i = Repository.invites()
            members = try await m; invites = try await i
        } catch { self.error = error.localizedDescription }
    }

    private func deleteInvites(_ idx: IndexSet) async {
        for i in idx { try? await Repository.deleteInvite(id: invites[i].id) }
        invites.remove(atOffsets: idx)
    }
}

struct NewInviteSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    let onCreated: (OrgInvite) -> Void

    @State private var role: MemberRole = .member
    @State private var email = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Role", selection: $role) {
                    Text("Member").tag(MemberRole.member)
                    Text("Admin").tag(MemberRole.admin)
                }
                TextField("Restrict to email (optional)", text: $email)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("New invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                }
            }
        }
    }

    private func create() async {
        guard let orgId = session.profile?.orgId, let userId = session.userId else { return }
        do {
            let inv = try await Repository.createInvite(orgId: orgId, userId: userId, role: role, email: email)
            onCreated(inv); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
