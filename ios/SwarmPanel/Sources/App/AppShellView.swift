import SwiftUI
import UIKit

/// The panel's top-level destinations, matching the web panel's sections
/// (lua/src/nav.lua). `controls` isn't a dock destination any more -- it's
/// the Deck, opened from the dock's centre orb -- but it stays a case so
/// quick actions, widgets and `swarmpanel://controls` links keep working.
enum SwarmTab: String, CaseIterable {
    case fleet, controls, insights, community, account

    /// Resolves a quick-action / `swarmpanel://` name. Accepts the tab names
    /// used before the section restructure (dashboard, leaderboard, social,
    /// profile) so existing shortcuts, widgets and bookmarks keep working.
    init?(linkName: String) {
        switch linkName.lowercased() {
        case "dashboard": self = .fleet
        case "leaderboard", "learning": self = .insights
        case "social", "users", "friends", "messages": self = .community
        case "profile", "appearance", "you": self = .account
        case "deck": self = .controls
        default:
            guard let tab = SwarmTab(rawValue: linkName.lowercased()) else { return nil }
            self = tab
        }
    }

    var title: String {
        switch self {
        case .fleet: return "Fleet"
        case .controls: return "Deck"
        case .insights: return "Insights"
        case .community: return "Community"
        case .account: return "You"
        }
    }

    var icon: String {
        switch self {
        case .fleet: return "hexagon"
        case .controls: return "slider.vertical.3"
        case .insights: return "chart.bar.xaxis"
        case .community: return "person.2"
        case .account: return "person.crop.circle"
        }
    }

    var selectedIcon: String {
        switch self {
        case .fleet: return "hexagon.fill"
        case .controls: return "slider.vertical.3"
        case .insights: return "chart.bar.xaxis"
        case .community: return "person.2.fill"
        case .account: return "person.crop.circle.fill"
        }
    }

    /// The four places the dock takes you, left to right around the Deck orb.
    static let dockDestinations: [SwarmTab] = [.fleet, .insights, .community, .account]
}

/// The signed-in app. Replaces the old five-tab `TabView` with four
/// destinations on a floating console dock, plus the Deck (Controls) on
/// the dock's centre orb:
///
/// - **Fleet** -- the live hive, your guild's now playing, every session.
/// - **Insights** -- leaderboard and what the recommender has learned.
/// - **Deck** -- send orders to a bot; opens over whatever you're looking at.
/// - **Community** -- directory, friends and messages.
/// - **You** -- your profile, appearance, security and (for staff) admin.
///
/// Each destination keeps its own view tree, built the first time it's
/// visited and kept alive afterwards, so switching back keeps scroll
/// position and pushed screens -- the way the `TabView` did. A custom
/// container is what lets the dock float, step aside for the keyboard and
/// hide on immersive screens (bot detail, message threads).
struct AppShellView: View {
    @StateObject private var notificationsViewModel = NotificationsViewModel()
    @StateObject private var toastCenter = ToastCenter()
    @StateObject private var dock = DockController()
    @EnvironmentObject private var router: DeepLinkRouter
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var biometricLock: BiometricLock

    @State private var selection: SwarmTab = .fleet
    @State private var mounted: Set<SwarmTab> = [.fleet]
    /// Bumped when the already-selected destination is tapped again, which
    /// rebuilds it -- back to its root, scrolled to the top.
    @State private var rootIds: [SwarmTab: UUID] = [:]
    @State private var showingDeck = false
    @State private var keyboardVisible = false
    @AppStorage("swarmpanel.lastSeenWhatsNewVersion") private var lastSeenVersion = ""
    @State private var showWhatsNew = false

    var body: some View {
        ZStack {
            ForEach(SwarmTab.dockDestinations, id: \.self) { tab in
                if mounted.contains(tab) {
                    root(for: tab)
                        .id(rootIds[tab])
                        .environment(\.dockTab, tab)
                        .opacity(selection == tab ? 1 : 0)
                        .allowsHitTesting(selection == tab)
                        .accessibilityHidden(selection != tab)
                }
            }
        }
        .environment(\.dockController, dock)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsDock {
                ConsoleDock(
                    selection: selection,
                    communityBadge: notificationsViewModel.communityBadge,
                    onSelect: select,
                    onDeck: openDeck
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showsDock)
        .environmentObject(notificationsViewModel)
        .environmentObject(toastCenter)
        .toastOverlay(toastCenter)
        .sheet(isPresented: $showingDeck) {
            ControlsView(onClose: { showingDeck = false })
                .environmentObject(notificationsViewModel)
                .environmentObject(toastCenter)
                .environmentObject(appState)
                .environmentObject(appearance)
                .environmentObject(router)
                .environmentObject(biometricLock)
                .environment(\.resAccent, appearance.accentColor)
                .tint(appearance.accentColor)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .onAppear {
            notificationsViewModel.startPolling()
            // A quick action that launched the app cold lands here before
            // onChange can observe it.
            if let pending = router.pendingTab {
                route(to: pending)
                router.pendingTab = nil
            }
            // Skip on a true first launch (nothing to compare against) but
            // still record the version so the next real update triggers this.
            if !lastSeenVersion.isEmpty && lastSeenVersion != currentAppVersion {
                showWhatsNew = true
            }
            lastSeenVersion = currentAppVersion
        }
        .onDisappear { notificationsViewModel.stopPolling() }
        .onChange(of: router.pendingTab) { newValue in
            guard let newValue else { return }
            route(to: newValue)
            router.pendingTab = nil
        }
        .sheet(isPresented: $showWhatsNew) {
            NavigationStack {
                WhatsNewView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showWhatsNew = false }
                        }
                    }
            }
            .environment(\.resAccent, appearance.accentColor)
        }
    }

    private var showsDock: Bool {
        !keyboardVisible && !dock.isHidden(in: selection)
    }

    @ViewBuilder
    private func root(for tab: SwarmTab) -> some View {
        switch tab {
        case .fleet: DashboardView()
        case .insights: LeaderboardView()
        case .community: SocialView()
        case .account: ProfileView()
        case .controls: EmptyView()
        }
    }

    private func select(_ tab: SwarmTab) {
        Haptics.light()
        if tab == selection {
            rootIds[tab] = UUID()
        } else {
            mounted.insert(tab)
            selection = tab
        }
    }

    private func openDeck() {
        Haptics.medium()
        showingDeck = true
    }

    private func route(to tab: SwarmTab) {
        if tab == .controls {
            showingDeck = true
        } else {
            mounted.insert(tab)
            selection = tab
        }
    }
}

// MARK: - Dock visibility

/// Tracks which on-screen views have asked for the dock to step aside,
/// per destination, so an immersive screen left open in one destination
/// doesn't hide the dock in another.
@MainActor
final class DockController: ObservableObject {
    @Published private var requests: [SwarmTab: Set<UUID>] = [:]

    func isHidden(in tab: SwarmTab) -> Bool {
        !(requests[tab]?.isEmpty ?? true)
    }

    func hide(_ token: UUID, in tab: SwarmTab) {
        requests[tab, default: []].insert(token)
    }

    func release(_ token: UUID, in tab: SwarmTab) {
        requests[tab]?.remove(token)
    }
}

private struct DockControllerKey: EnvironmentKey {
    static let defaultValue: DockController? = nil
}

private struct DockTabKey: EnvironmentKey {
    static let defaultValue: SwarmTab = .fleet
}

extension EnvironmentValues {
    var dockController: DockController? {
        get { self[DockControllerKey.self] }
        set { self[DockControllerKey.self] = newValue }
    }

    var dockTab: SwarmTab {
        get { self[DockTabKey.self] }
        set { self[DockTabKey.self] = newValue }
    }
}

private struct HidesDock: ViewModifier {
    @Environment(\.dockController) private var dock
    @Environment(\.dockTab) private var tab
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { dock?.hide(token, in: tab) }
            .onDisappear { dock?.release(token, in: tab) }
    }
}

extension View {
    /// Hides the floating dock while this view is on screen. A no-op
    /// outside the shell (sheets, previews).
    func hidesDock() -> some View {
        modifier(HidesDock())
    }

    /// Room at the bottom of a scrolling screen so its last row isn't left
    /// under the floating dock.
    func dockClearance() -> some View {
        padding(.bottom, 12)
    }
}

#Preview {
    AppShellView()
        .environmentObject(AppState())
        .environmentObject(AppearanceSettings())
        .environmentObject(DeepLinkRouter())
        .environmentObject(BiometricLock())
}
