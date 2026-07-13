import SwiftUI

/// Authenticated shell — every tab is now a real screen (Dashboard, Controls,
/// Leaderboard, Notifications, Social, Profile). NotificationsViewModel is
/// owned here (not inside NotificationsView) so its unread-count poll —
/// mirroring the web bell's always-on polling in Shell.jsx — keeps running no
/// matter which tab is selected, and can drive the tab badge.
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

            NotificationsView(viewModel: notificationsViewModel)
                .tabItem { Label("Notifications", systemImage: "bell") }
                .badge(notificationsViewModel.unreadCount)

            SocialView()
                .tabItem { Label("Social", systemImage: "person.2") }

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
        .onAppear { notificationsViewModel.startPolling() }
        .onDisappear { notificationsViewModel.stopPolling() }
    }
}

#Preview {
    RootTabView()
        .environmentObject(AppState())
        .environmentObject(AppearanceSettings())
}
