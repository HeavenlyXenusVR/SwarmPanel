import SwiftUI

/// Authenticated shell. Dashboard, Controls, Leaderboard, and Notifications
/// are real; the remaining tabs are filled in by later build phases (Social,
/// Profile) — kept as simple placeholders here so the tab bar structure
/// exists end-to-end. NotificationsViewModel is owned here (not inside
/// NotificationsView) so its unread-count poll — mirroring the web bell's
/// always-on polling in Shell.jsx — keeps running no matter which tab is
/// selected, and can drive the tab badge.
struct RootTabView: View {
    @EnvironmentObject private var appState: AppState
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

            ComingSoonView(title: "Social", systemImage: "person.2")
                .tabItem { Label("Social", systemImage: "person.2") }

            ProfileTabPlaceholder()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
        .onAppear { notificationsViewModel.startPolling() }
        .onDisappear { notificationsViewModel.stopPolling() }
    }
}

private struct ComingSoonView: View {
    let title: String
    let systemImage: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("\(title) is coming in a later build phase.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .navigationTitle(title)
        }
    }
}

private struct ProfileTabPlaceholder: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    LabeledContent("Username", value: appState.username)
                    if let guildId = appState.guildId {
                        LabeledContent("Guild", value: guildId)
                    }
                }
                Section {
                    Button("Log Out", role: .destructive) { appState.logout() }
                }
            }
            .navigationTitle("Profile")
        }
    }
}

#Preview {
    RootTabView()
        .environmentObject(AppState())
}
