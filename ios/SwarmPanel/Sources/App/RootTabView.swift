import SwiftUI

/// Authenticated shell — 5 tabs (Dashboard, Controls, Leaderboard, Social,
/// Profile). Notifications is deliberately NOT a 6th tab: iOS auto-folds
/// TabView overflow beyond 5 items into a plain unstyled "More" list, which
/// silently buried two tabs behind an extra tap. Instead, NotificationsViewModel
/// is owned here and injected via environment so every screen can show a
/// bell + badge in its own toolbar (see DesignSystem/NotificationsBell.swift)
/// — the poll keeps running no matter which tab is selected.
enum SwarmTab: String, CaseIterable {
    case dashboard, controls, leaderboard, social, profile
}

struct RootTabView: View {
    @StateObject private var notificationsViewModel = NotificationsViewModel()
    @StateObject private var toastCenter = ToastCenter()
    @EnvironmentObject private var router: DeepLinkRouter
    @State private var selectedTab: SwarmTab = .dashboard

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2") }
                .tag(SwarmTab.dashboard)

            ControlsView()
                .tabItem { Label("Controls", systemImage: "play.circle") }
                .tag(SwarmTab.controls)

            LeaderboardView()
                .tabItem { Label("Leaderboard", systemImage: "trophy") }
                .tag(SwarmTab.leaderboard)

            SocialView()
                .tabItem { Label("Social", systemImage: "person.2") }
                .tag(SwarmTab.social)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(SwarmTab.profile)
        }
        .environmentObject(notificationsViewModel)
        .environmentObject(toastCenter)
        .toastOverlay(toastCenter)
        .onAppear { notificationsViewModel.startPolling() }
        .onDisappear { notificationsViewModel.stopPolling() }
        .onChange(of: router.pendingTab) { newValue in
            guard let newValue else { return }
            selectedTab = newValue
            router.pendingTab = nil
        }
    }
}

#Preview {
    RootTabView()
        .environmentObject(AppState())
        .environmentObject(AppearanceSettings())
        .environmentObject(DeepLinkRouter())
}
