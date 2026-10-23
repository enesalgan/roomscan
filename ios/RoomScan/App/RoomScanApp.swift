import SwiftUI

@main
struct RoomScanApp: App {
    @State private var session = SessionStore()
    @State private var store = StoreService()
    @State private var language = AppLanguage.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .id(language.code)                       // rebuild the tree when the language changes
                .environment(\.locale, language.locale)
                .environment(session)
                .environment(store)
                .environment(language)
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
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
            JobsListView()
                .tabItem { Label("Jobs", systemImage: "list.clipboard") }
            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
            ReportsView()
                .tabItem { Label("Reports", systemImage: "chart.bar.xaxis") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
