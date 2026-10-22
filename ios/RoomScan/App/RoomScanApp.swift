import SwiftUI

@main
struct RoomScanApp: App {
    @State private var session = SessionStore()
    @State private var store = StoreService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(store)
                .task { await session.start() }
                .task { await store.start() }
        }
    }
}

struct RootView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        Group {
            switch session.state {
            case .loading:
                ProgressView("Loading…")
            case .signedOut:
                AuthView()
            case .signedIn:
                MainTabView()
            }
        }
        .animation(.default, value: session.state)
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            JobsListView()
                .tabItem { Label("Jobs", systemImage: "list.clipboard") }
            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
