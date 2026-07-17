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
    @AppStorage("swarmpanel.lastSeenWhatsNewVersion") private var lastSeenVersion = ""
    @State private var showWhatsNew = false

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: selectedTab == .dashboard ? "square.grid.2x2.fill" : "square.grid.2x2") }
                .tag(SwarmTab.dashboard)

            ControlsView()
                .tabItem { Label("Controls", systemImage: selectedTab == .controls ? "play.circle.fill" : "play.circle") }
                .tag(SwarmTab.controls)

            LeaderboardView()
                .tabItem { Label("Leaderboard", systemImage: selectedTab == .leaderboard ? "trophy.fill" : "trophy") }
                .tag(SwarmTab.leaderboard)

            SocialView()
                .tabItem { Label("Social", systemImage: selectedTab == .social ? "person.2.fill" : "person.2") }
                .tag(SwarmTab.social)

            ProfileView()
                .tabItem { Label("Profile", systemImage: selectedTab == .profile ? "person.crop.circle.fill" : "person.crop.circle") }
                .tag(SwarmTab.profile)
        }
        .environmentObject(notificationsViewModel)
        .environmentObject(toastCenter)
        .toastOverlay(toastCenter)
        .onAppear {
            notificationsViewModel.startPolling()
            // Skip on a true first launch (nothing to compare against) but
            // still record the version so the next real update triggers this.
            if !lastSeenVersion.isEmpty && lastSeenVersion != currentAppVersion {
                showWhatsNew = true
            }
            lastSeenVersion = currentAppVersion
        }
        .onDisappear { notificationsViewModel.stopPolling() }
        .onChange(of: router.pendingTab) { newValue in
            guard let newValue else { return }
            selectedTab = newValue
            router.pendingTab = nil
        }
        .sheet(isPresented: $showWhatsNew) {
            NavigationStack {
                WhatsNewView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showWhatsNew = false }
                        }
                    }
            }
        }
    }
}

#Preview {
    RootTabView()
        .environmentObject(AppState())
        .environmentObject(AppearanceSettings())
        .environmentObject(DeepLinkRouter())
}
