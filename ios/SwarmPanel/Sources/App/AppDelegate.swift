import UIKit

/// Hosts the home-screen Quick Actions (long-press the app icon) — set
/// programmatically rather than via static Info.plist entries so each one
/// can use an SF Symbol instead of the limited built-in icon set. Bridges
/// into `DeepLinkRouter` once the SwiftUI environment attaches itself.
final class AppDelegate: NSObject, UIApplicationDelegate {
    weak var router: DeepLinkRouter?
    var pendingShortcutType: String?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.shortcutItems = [
            UIApplicationShortcutItem(
                type: "com.swarmpanel.ios.open-dashboard",
                localizedTitle: "Dashboard",
                localizedSubtitle: "Fleet status",
                icon: UIApplicationShortcutIcon(systemImageName: "square.grid.2x2")
            ),
            UIApplicationShortcutItem(
                type: "com.swarmpanel.ios.open-controls",
                localizedTitle: "Controls",
                localizedSubtitle: "Send a bot action",
                icon: UIApplicationShortcutIcon(systemImageName: "play.circle")
            ),
            UIApplicationShortcutItem(
                type: "com.swarmpanel.ios.open-leaderboard",
                localizedTitle: "Leaderboard",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "trophy")
            ),
        ]

        if let shortcut = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            pendingShortcutType = shortcut.type
        }
        return true
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        router?.handleShortcut(identifier: shortcutItem.type)
        completionHandler(true)
    }
}
