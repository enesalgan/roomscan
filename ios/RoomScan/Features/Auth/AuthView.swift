import SwiftUI

struct AuthView: View {
    @Environment(SessionStore.self) private var session

    enum Mode: String, CaseIterable { case signIn = "Sign In", signUp = "Create Account" }
    enum AccountKind: String, CaseIterable, Identifiable {
        case individual = "Individual", company = "Company / Branch", invite = "Join with code"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .signIn
    @State private var kind: AccountKind = .company
    @State private var email = ""
    @State private var password = ""
    @State private var fullName = ""
    @State private var orgName = ""
    @State private var inviteCode = ""
    @State private var busy = false
    @State private var error: String?
    @State private var info: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 6) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 44)).foregroundStyle(.tint)
                        Text("RoomScan").font(.title.bold())
                        Text("LiDAR room scans, photos and jobs — in one place.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                Section {
                    if mode == .signUp {
                        TextField("Full name", text: $fullName).textContentType(.name)
                    }
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress).textContentType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(mode == .signUp ? .newPassword : .password)
                }

                if mode == .signUp {
                    Section("Account type") {
                        Picker("Account type", selection: $kind) {
                            ForEach(AccountKind.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                        }
                        .pickerStyle(.inline).labelsHidden()

                        switch kind {
                        case .company:
                            TextField("Company or branch name", text: $orgName)
                            Text("You'll be the owner and can invite staff from Settings.")
                                .font(.footnote).foregroundStyle(.secondary)
                        case .invite:
                            TextField("Invite code", text: $inviteCode)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            Text("Ask your branch owner for an invite code.")
                                .font(.footnote).foregroundStyle(.secondary)
                        case .individual:
                            Text("\(Config.freeScans) free scans, then upgrade anytime.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                if let info { Text(info).foregroundStyle(.green).font(.footnote) }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text(LocalizedStringKey(mode.rawValue)).bold() }
                            Spacer()
                        }
                    }
                    .disabled(busy || !isValid)

                    if mode == .signIn {
                        Button("Forgot password?") { Task { await forgot() } }
                            .font(.footnote).disabled(email.isEmpty)
                    }
                }

                Section {
                    Button {
                        session.enterDemo()
                    } label: {
                        HStack { Spacer(); Label("Try the demo — no account needed", systemImage: "play.circle"); Spacer() }
                    }
                } footer: {
                    Text("Everything stays on this device. \(Config.freeScans) free scans, then the upgrade screen.")
                }
            }
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var isValid: Bool {
        guard email.contains("@"), password.count >= 6 else { return false }
        if mode == .signUp {
            if fullName.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            if kind == .company && orgName.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            if kind == .invite && inviteCode.count < 6 { return false }
        }
        return true
    }

    private func submit() async {
        busy = true; error = nil; info = nil
        defer { busy = false }
        do {
            switch mode {
            case .signIn:
                try await session.signIn(email: email, password: password)
            case .signUp:
                let k: SessionStore.SignupKind = switch kind {
                case .individual: .individual
                case .company: .company(orgName.trimmingCharacters(in: .whitespaces))
                case .invite: .invite(inviteCode.trimmingCharacters(in: .whitespaces))
                }
                try await session.signUp(email: email, password: password, fullName: fullName, kind: k)
                // If email confirmation is enabled in Supabase, the session won't exist yet.
                if session.state != .signedIn {
                    info = "Check your email to confirm your account, then sign in."
                    mode = .signIn
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func forgot() async {
        do { try await session.resetPassword(email: email); info = "Password reset email sent." }
        catch { self.error = error.localizedDescription }
    }
}
