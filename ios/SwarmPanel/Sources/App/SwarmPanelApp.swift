import SwiftUI
import UIKit

@main
struct SwarmPanelApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var appearance = AppearanceSettings()

    init() {
        Self.configureGlobalChrome()
    }

    /// UIKit appearance proxies for the tab bar / nav bar — SwiftUI has no
    /// pure-SwiftUI equivalent for this, and without it every screen's chrome
    /// stays plain system-gray no matter how the content underneath is styled.
    /// Colors are dynamic (SwarmTheme), so this still follows light/dark mode.
    private static func configureGlobalChrome() {
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor(SwarmTheme.panel)
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = UIColor(SwarmTheme.panel)
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor(SwarmTheme.textPrimary)]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor(SwarmTheme.textPrimary)]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
    }

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
