import Foundation

/// Bridges non-SwiftUI entry points (home screen quick actions, the
/// `swarmpanel://` URL scheme) into a tab switch. RootTabView observes
/// `pendingTab` and clears it once applied.
@MainActor
final class DeepLinkRouter: ObservableObject {
    @Published var pendingTab: SwarmTab?

    /// Quick action identifiers are `"com.swarmpanel.ios.open-<tab>"`
    /// (see project.yml's UIApplicationShortcutItems); URL hosts are the
    /// bare tab name, e.g. `swarmpanel://controls`.
    func resolve(identifier: String) -> SwarmTab? {
        let name = identifier
            .replacingOccurrences(of: "com.swarmpanel.ios.open-", with: "")
            .lowercased()
        return SwarmTab(rawValue: name)
    }

    func handleShortcut(identifier: String) {
        guard let tab = resolve(identifier: identifier) else { return }
        pendingTab = tab
    }

    func handleURL(_ url: URL) {
        guard url.scheme == "swarmpanel", let host = url.host else { return }
        guard let tab = SwarmTab(rawValue: host.lowercased()) else { return }
        pendingTab = tab
    }
}
