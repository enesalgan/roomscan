import Foundation
import Observation
import Supabase

/// Auth session + current profile / organization / entitlement.
@Observable
@MainActor
final class SessionStore {
    enum State: Equatable { case loading, signedOut, signedIn }

    var state: State = .loading
    var userId: UUID?
    var profile: Profile?
    var organization: Organization?
    var entitlement = Entitlement()
    var lastError: String?
    var isDemo = false

    private var listenerTask: Task<Void, Never>?

    func start() async {
        listenerTask?.cancel()
        listenerTask = Task {
            for await (event, session) in supabase.auth.authStateChanges {
                switch event {
                case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
                    if isDemo { break }
                    if let session {
                        userId = session.user.id
                        await loadContext()
                        state = .signedIn
                    } else {
                        state = .signedOut
                    }
                case .signedOut, .userDeleted:
                    if isDemo { break }   // demo session is local; ignore Supabase auth events
                    userId = nil; profile = nil; organization = nil; entitlement = Entitlement()
                    state = .signedOut
                default:
                    break
                }
            }
        }
    }

    func loadContext() async {
        guard let userId else { return }
        do {
            // Profile is created by a DB trigger right after signup; retry briefly if it isn't there yet.
            var p: Profile?
            for _ in 0..<5 {
                p = try? await supabase.from("profiles").select().eq("id", value: userId).single().execute().value
                if p != nil { break }
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard let p else { throw AppError.message("Profile not found. Please sign in again.") }
            profile = p
            organization = try await supabase.from("organizations").select().eq("id", value: p.orgId).single().execute().value
            if let org = organization { await BrandingStore.shared.load(for: org, demo: false) }
            await refreshEntitlement()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshEntitlement() async {
        if isDemo { entitlement = DemoStore.shared.entitlement; return }
        do {
            entitlement = try await supabase.rpc("my_entitlement").execute().value
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Auth actions

    func signIn(email: String, password: String) async throws {
        try await supabase.auth.signIn(email: email, password: password)
    }

    /// kind: .individual | .company(name) | .invite(code)
    enum SignupKind { case individual, company(String), invite(String) }

    func signUp(email: String, password: String, fullName: String, kind: SignupKind, profession: Profession) async throws {
        var meta: [String: AnyJSON] = ["full_name": .string(fullName), "profession": .string(profession.rawValue)]
        switch kind {
        case .individual: break
        case .company(let name): meta["org_name"] = .string(name)
        case .invite(let code): meta["invite_code"] = .string(code.uppercased())
        }
        try await supabase.auth.signUp(email: email, password: password, data: meta)
    }

    func setProfession(_ p: Profession) async {
        guard let userId else { return }
        do { try await Repository.updateProfession(p, userId: userId); profile?.profession = p }
        catch { lastError = error.localizedDescription }
    }

    func signOut() async {
        if isDemo { exitDemo(); return }
        try? await supabase.auth.signOut()
    }

    // MARK: Demo mode (no backend)

    func enterDemo() {
        DemoStore.shared.enter()
        isDemo = true
        userId = DemoStore.shared.userId
        profile = DemoStore.shared.profile
        organization = DemoStore.shared.organization
        entitlement = DemoStore.shared.entitlement
        state = .signedIn
        Task { await BrandingStore.shared.load(for: DemoStore.shared.organization, demo: true) }
    }

    func exitDemo() {
        DemoStore.shared.exit()
        isDemo = false
        userId = nil; profile = nil; organization = nil; entitlement = Entitlement()
        state = .signedOut
    }

    func resetPassword(email: String) async throws {
        try await supabase.auth.resetPasswordForEmail(email)
    }
}
