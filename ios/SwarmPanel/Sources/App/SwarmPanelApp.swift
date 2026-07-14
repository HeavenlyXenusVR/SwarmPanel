import SwiftUI
import UIKit
import UserNotifications

@main
struct SwarmPanelApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState = AppState()
    @StateObject private var appearance = AppearanceSettings()
    @StateObject private var router = DeepLinkRouter()
    @StateObject private var biometricLock = BiometricLock()

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
                .environmentObject(router)
                .environmentObject(biometricLock)
                .tint(appearance.accentColor)
                .preferredColorScheme(appearance.colorScheme)
                .overlay(BiometricLockOverlay(lock: biometricLock))
                .task { await appState.bootstrap() }
                .task {
                    // Badge-only authorization (no alerts/sounds) so the app
                    // icon can reflect unread notification count — declining
                    // this just means the badge silently never appears.
                    try? await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])
                }
                .onAppear {
                    appDelegate.router = router
                    if let type = appDelegate.pendingShortcutType {
                        router.handleShortcut(identifier: type)
                        appDelegate.pendingShortcutType = nil
                    }
                }
                .onOpenURL { url in router.handleURL(url) }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .background { biometricLock.lock() }
                }
        }
    }
}
