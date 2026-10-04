import SwiftUI

/// Auth-gated root: shows a launch spinner while the stored token (if any) is
/// being validated, Login when signed out, and the authenticated tab bar
/// (AppShellView) once signed in.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.isBootstrapping {
                LaunchView()
            } else if appState.isAuthenticated {
                AppShellView()
            } else {
                LoginView()
            }
        }
    }
}

/// Shown while a stored session is being validated: the emblem listening
/// on the Resonance sky.
private struct LaunchView: View {
    var body: some View {
        ZStack {
            ResonanceBackdrop().ignoresSafeArea()
            VStack(spacing: 20) {
                ResonanceEmblem(size: 140)
                Text("SwarmPanel")
                    .font(Res.display(30))
                    .foregroundStyle(Res.ink)
                Text("Tuning in to the fleet…")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(Res.mist)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading SwarmPanel")
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
