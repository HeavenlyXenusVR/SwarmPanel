import SwiftUI

/// Authenticated shell — 5 tabs matching the web panel's sections (see
/// lua/src/nav.lua): Fleet (Dashboard + Invites), Controls, Insights
/// (Leaderboard + Learning), Community (Directory, Friends, Messages) and
/// Account (Profile, Appearance, and — for staff — the Admin tools hub).
/// Notifications is deliberately NOT a 6th tab: iOS auto-folds TabView
/// overflow beyond 5 items into a plain unstyled "More" list, which silently
/// buried two tabs behind an extra tap. Instead, NotificationsViewModel is
/// owned here and injected via environment so every screen can show a bell
/// + badge in its own toolbar (see DesignSystem/NotificationsBell.swift) —
/// the poll keeps running no matter which tab is selected.
enum SwarmTab: String, CaseIterable {
    case fleet, controls, insights, community, account

    /// Resolves a quick-action / `swarmpanel://` name. Accepts the tab names
    /// used before the section restructure (dashboard, leaderboard, social,
    /// profile) so existing shortcuts, widgets and bookmarks keep working.
    init?(linkName: String) {
        switch linkName.lowercased() {
        case "dashboard": self = .fleet
        case "leaderboard", "learning": self = .insights
        case "social", "users", "friends", "messages": self = .community
        case "profile", "appearance": self = .account
        default:
            guard let tab = SwarmTab(rawValue: linkName.lowercased()) else { return nil }
            self = tab
        }
    }
}

struct RootTabView: View {
    @StateObject private var notificationsViewModel = NotificationsViewModel()
    @StateObject private var toastCenter = ToastCenter()
    @EnvironmentObject private var router: DeepLinkRouter
    @State private var selectedTab: SwarmTab = .fleet
    @AppStorage("swarmpanel.lastSeenWhatsNewVersion") private var lastSeenVersion = ""
    @State private var showWhatsNew = false

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem { Label("Fleet", systemImage: selectedTab == .fleet ? "square.grid.2x2.fill" : "square.grid.2x2") }
                .tag(SwarmTab.fleet)

            ControlsView()
                .tabItem { Label("Controls", systemImage: selectedTab == .controls ? "play.circle.fill" : "play.circle") }
                .tag(SwarmTab.controls)

            LeaderboardView()
                .tabItem { Label("Insights", systemImage: selectedTab == .insights ? "chart.bar.fill" : "chart.bar") }
                .tag(SwarmTab.insights)

            SocialView()
                .tabItem { Label("Community", systemImage: selectedTab == .community ? "person.2.fill" : "person.2") }
                .tag(SwarmTab.community)

            ProfileView()
                .tabItem { Label("Account", systemImage: selectedTab == .account ? "person.crop.circle.fill" : "person.crop.circle") }
                .tag(SwarmTab.account)
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
