import SwiftUI

/// Auth-gated root: shows a launch spinner while the stored token (if any) is
/// being validated, Login when signed out, and the authenticated tab bar
/// (RootTabView) once signed in.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.isBootstrapping {
                ProgressView("Loading SwarmPanel...")
            } else if appState.isAuthenticated {
                RootTabView()
            } else {
                LoginView()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
