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
    @State private var activeSince = Date()

    init() {
        Self.configureGlobalChrome()
        // Must be registered before the app finishes launching — doing this
        // from a .task (after the first view appears) is too late per
        // BGTaskScheduler's contract.
        BackgroundRefreshManager.register()
    }

    /// UIKit appearance proxies for the navigation bar: transparent at the
    /// top of a screen so the Resonance backdrop runs edge to edge, a soft
    /// blur once content scrolls under it, and rounded heavy titles to match
    /// the rest of the app. Colors are dynamic, so this follows light/dark.
    private static func configureGlobalChrome() {
        let titleColor = UIColor(Res.ink)
        let rounded = UIFont.systemFont(ofSize: 34, weight: .heavy).fontDescriptor.withDesign(.rounded)
        let inline = UIFont.systemFont(ofSize: 17, weight: .bold).fontDescriptor.withDesign(.rounded)

        func styled(_ appearance: UINavigationBarAppearance) -> UINavigationBarAppearance {
            appearance.titleTextAttributes = [
                .foregroundColor: titleColor,
                .font: inline.map { UIFont(descriptor: $0, size: 17) } ?? UIFont.systemFont(ofSize: 17, weight: .bold),
            ]
            appearance.largeTitleTextAttributes = [
                .foregroundColor: titleColor,
                .font: rounded.map { UIFont(descriptor: $0, size: 34) } ?? UIFont.systemFont(ofSize: 34, weight: .heavy),
            ]
            appearance.shadowColor = .clear
            return appearance
        }

        let edge = UINavigationBarAppearance()
        edge.configureWithTransparentBackground()
        let scrolled = UINavigationBarAppearance()
        scrolled.configureWithDefaultBackground()
        scrolled.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)

        UINavigationBar.appearance().standardAppearance = styled(scrolled)
        UINavigationBar.appearance().compactAppearance = styled(scrolled)
        UINavigationBar.appearance().scrollEdgeAppearance = styled(edge)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appearance)
                .environmentObject(router)
                .environmentObject(biometricLock)
                .tint(appearance.accentColor)
                .environment(\.resAccent, appearance.accentColor)
                .preferredColorScheme(appearance.colorScheme)
                .overlay(BiometricLockOverlay(lock: biometricLock))
                .task { await appState.bootstrap() }
                .task {
                    // Full alert/sound/badge authorization — this app has no
                    // paid Apple Developer account for real APNs push, so
                    // BackgroundRefreshManager's opportunistic background
                    // fetch + locally-delivered banners are the workaround;
                    // badge-only auth would silently suppress those banners.
                    // Declining just means neither badges nor banners appear.
                    try? await UNUserNotificationCenter.current().requestAuthorization(options: [.badge, .sound, .alert])
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
                    switch newPhase {
                    case .active:
                        activeSince = Date()
                        ClientTelemetry.shared.log("app_foreground")
                        // A suspended app's refresh timer doesn't run, so
                        // renew the session and bring the live socket back
                        // immediately rather than waiting for the next tick.
                        Task { await appState.refreshSession() }
                        if appState.isAuthenticated { SwarmLiveSocket.shared.connect() }
                    case .background:
                        biometricLock.lock()
                        BackgroundRefreshManager.scheduleNext()
                        ClientTelemetry.shared.log("app_background",
                                                   value: Date().timeIntervalSince(activeSince).rounded())
                        Task { await ClientTelemetry.shared.flush() }
                    default:
                        break
                    }
                }
        }
    }
}
