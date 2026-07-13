import SwiftUI

/// Authenticated shell — 5 tabs (Dashboard, Controls, Leaderboard, Social,
/// Profile). Notifications is deliberately NOT a 6th tab: iOS auto-folds
/// TabView overflow beyond 5 items into a plain unstyled "More" list, which
/// silently buried two tabs behind an extra tap. Instead, NotificationsViewModel
/// is owned here and injected via environment so every screen can show a
/// bell + badge in its own toolbar (see DesignSystem/NotificationsBell.swift)
/// — the poll keeps running no matter which tab is selected.
struct RootTabView: View {
    @StateObject private var notificationsViewModel = NotificationsViewModel()

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2") }

            ControlsView()
                .tabItem { Label("Controls", systemImage: "play.circle") }

            LeaderboardView()
                .tabItem { Label("Leaderboard", systemImage: "trophy") }

            SocialView()
                .tabItem { Label("Social", systemImage: "person.2") }

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
        .environmentObject(notificationsViewModel)
        .onAppear { notificationsViewModel.startPolling() }
        .onDisappear { notificationsViewModel.stopPolling() }
    }
}

#Preview {
    RootTabView()
        .environmentObject(AppState())
        .environmentObject(AppearanceSettings())
}
