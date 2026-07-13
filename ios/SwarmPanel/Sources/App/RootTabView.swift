import SwiftUI

/// Authenticated shell. Dashboard, Controls, and Leaderboard are real; the
/// remaining tabs are filled in by later build phases (Social, Profile) —
/// kept as simple placeholders here so the tab bar structure exists end-to-end.
struct RootTabView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2") }

            ControlsView()
                .tabItem { Label("Controls", systemImage: "play.circle") }

            LeaderboardView()
                .tabItem { Label("Leaderboard", systemImage: "trophy") }

            ComingSoonView(title: "Social", systemImage: "person.2")
                .tabItem { Label("Social", systemImage: "person.2") }

            ProfileTabPlaceholder()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
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
