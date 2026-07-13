import SwiftUI

/// Auth-gated root: shows a launch spinner while the stored token (if any) is
/// being validated, Login when signed out, and the authenticated shell once
/// signed in. The authenticated shell is a placeholder here — Phase 3 replaces
/// it with the real tab bar (Dashboard/Controls/Leaderboard/Social/Profile).
struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.isBootstrapping {
                ProgressView("Loading SwarmPanel...")
            } else if appState.isAuthenticated {
                SignedInPlaceholderView()
            } else {
                LoginView()
            }
        }
    }
}

private struct SignedInPlaceholderView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("Signed in as \(appState.username)")
                    .font(.title2.bold())
                if let guildId = appState.guildId {
                    Text("Guild \(guildId)")
                        .foregroundStyle(.secondary)
                }
                Text("Dashboard, Controls, and the rest of the app arrive in the next build phases.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Log Out", role: .destructive) { appState.logout() }
                    .padding(.top)
            }
            .padding()
            .navigationTitle("SwarmPanel")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
