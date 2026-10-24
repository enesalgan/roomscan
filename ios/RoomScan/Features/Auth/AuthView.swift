import SwiftUI

struct AuthView: View {
    @Environment(SessionStore.self) private var session

    enum Mode: String, CaseIterable { case signIn = "Sign In", signUp = "Create Account" }
    enum AccountKind: String, CaseIterable, Identifiable {
        case company = "Company / Branch", individual = "Individual", invite = "Join with code"
        var id: String { rawValue }
        var icon: String { switch self { case .company: "building.2"; case .individual: "person"; case .invite: "ticket" } }
    }

    @State private var mode: Mode = .signIn
    @State private var kind: AccountKind = .company
    @State private var profession: Profession = .contractor
    @State private var email = ""
    @State private var password = ""
    @State private var fullName = ""
    @State private var orgName = ""
    @State private var inviteCode = ""
    @State private var busy = false
    @State private var error: String?
    @State private var info: String?
    @FocusState private var focus: Field?
    private enum Field { case name, email, password, org, code }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                modePicker
                fields
                if mode == .signUp { professionPicker; accountType }
                messages
                primaryButton
                if mode == .signIn {
                    Button("Forgot password?") { Task { await forgot() } }
                        .font(.footnote.weight(.medium)).disabled(email.isEmpty)
                }
                demoButton
            }
            .padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.055, green: 0.102, blue: 0.184), Color(red: 0.043, green: 0.102, blue: 0.227)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
                Image(systemName: "viewfinder")
                    .font(.system(size: 36, weight: .thin)).foregroundStyle(.white)
                Image(systemName: "cube")
                    .font(.system(size: 17, weight: .regular)).foregroundStyle(.white.opacity(0.9))
            }
            VStack(spacing: 4) {
                Text("RoomScan").font(.system(size: 28, weight: .bold)).fontDesign(.rounded)
                Text("LiDAR room scans, photos and jobs — in one place.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.top, 8)
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button { withAnimation(.snappy) { mode = m; error = nil; info = nil } } label: {
                    Text(LocalizedStringKey(m.rawValue))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(mode == m ? Color(.secondarySystemGroupedBackground) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(mode == m ? .primary : .secondary)
                        .shadow(color: mode == m ? .black.opacity(0.08) : .clear, radius: 4, y: 2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var fields: some View {
        VStack(spacing: 10) {
            if mode == .signUp {
                field("person", placeholder: "Full name", text: $fullName, focus: .name, content: .name, caps: .words, submit: .next) { focus = .email }
            }
            field("envelope", placeholder: "Email", text: $email, focus: .email, content: .emailAddress, keyboard: .emailAddress, submit: .next) { focus = .password }
            field("lock", placeholder: "Password", text: $password, focus: .password, secure: true,
                  content: mode == .signUp ? .newPassword : .password, submit: .go) { Task { await submit() } }
        }
    }

    private var professionPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("I am a…").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Profession.allCases) { p in
                        Button {
                            withAnimation(.snappy) {
                                profession = p
                                if p == .homeowner { kind = .individual } else if kind == .individual { kind = .company }
                            }
                        } label: {
                            Label(p.title, systemImage: p.icon).font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).frame(height: 38)
                                .background(profession == p ? Color.accentColor.opacity(0.12) : Color(.secondarySystemGroupedBackground), in: Capsule())
                                .overlay(Capsule().stroke(profession == p ? Color.accentColor : .clear, lineWidth: 1.5))
                                .foregroundStyle(profession == p ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var accountType: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Account type").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            HStack(spacing: 8) {
                ForEach(AccountKind.allCases) { k in
                    Button { withAnimation(.snappy) { kind = k } } label: {
                        VStack(spacing: 8) {
                            Image(systemName: k.icon).font(.title3)
                            Text(LocalizedStringKey(k.rawValue)).font(.caption.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity).frame(height: 76)
                        .background(kind == k ? Color.accentColor.opacity(0.12) : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(kind == k ? Color.accentColor : .clear, lineWidth: 1.5))
                        .foregroundStyle(kind == k ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            switch kind {
            case .company:
                field("building.2", placeholder: "Company or branch name", text: $orgName, focus: .org, content: .organizationName, caps: .words, submit: .go) { Task { await submit() } }
                hint("You'll be the owner and can invite staff from Settings.")
            case .invite:
                field("ticket", placeholder: "Invite code", text: $inviteCode, focus: .code, caps: .characters, submit: .go) { Task { await submit() } }
                hint("Ask your branch owner for an invite code.")
            case .individual:
                hint("\(Config.freeScans) free scans, then upgrade anytime.")
            }
        }
    }

    private func hint(_ key: LocalizedStringKey) -> some View {
        Text(key).font(.footnote).foregroundStyle(.secondary).padding(.leading, 4)
    }

    @ViewBuilder private var messages: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let info {
            Label(info, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var primaryButton: some View {
        Button { Task { await submit() } } label: {
            HStack {
                if busy { ProgressView().tint(.white) }
                Text(LocalizedStringKey(mode.rawValue)).font(.headline)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .disabled(busy || !isValid)
    }

    private var demoButton: some View {
        VStack(spacing: 6) {
            Button { session.enterDemo() } label: {
                Label("Try the demo — no account needed", systemImage: "play.circle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            Text("Everything stays on this device. \(Config.freeScans) free scans, then the upgrade screen.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(.top, 6)
    }

    private func field(_ icon: String, placeholder: LocalizedStringKey, text: Binding<String>, focus f: Field, secure: Bool = false,
                       content: UITextContentType? = nil, keyboard: UIKeyboardType = .default,
                       caps: TextInputAutocapitalization = .never, submit: SubmitLabel = .done, onSubmit: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(focus == f ? Color.accentColor : .secondary).frame(width: 20)
            Group {
                if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text) }
            }
            .textContentType(content)
            .keyboardType(keyboard)
            .textInputAutocapitalization(caps)
            .autocorrectionDisabled()
            .submitLabel(submit)
            .onSubmit(onSubmit)
            .focused($focus, equals: f)
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(focus == f ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5))
    }

    // MARK: Logic

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
        guard isValid else { return }
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
                try await session.signUp(email: email, password: password, fullName: fullName, kind: k, profession: profession)
                if session.state != .signedIn {
                    info = String(localized: "Check your email to confirm your account, then sign in.")
                    mode = .signIn
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func forgot() async {
        do { try await session.resetPassword(email: email); info = String(localized: "Password reset email sent.") }
        catch { self.error = error.localizedDescription }
    }
}
