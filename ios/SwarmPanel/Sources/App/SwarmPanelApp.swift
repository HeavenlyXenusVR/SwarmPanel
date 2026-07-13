import SwiftUI

@main
struct SwarmPanelApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task { await appState.bootstrap() }
        }
    }
}
