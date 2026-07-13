import SwiftUI

@main
struct SwarmPanelApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var appearance = AppearanceSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appearance)
                .tint(appearance.accentColor)
                .preferredColorScheme(appearance.colorScheme)
                .task { await appState.bootstrap() }
        }
    }
}
