import SwiftUI

/// `.task`/`.refreshable` alone only fire on first appearance or an explicit
/// pull — they never re-run just because the app sat backgrounded for a
/// while and came back. This fires `action` whenever `scenePhase` transitions
/// into `.active` from anything else, so a screen shows live data again the
/// moment the user returns to it instead of stale data until the next manual
/// pull-to-refresh (or a relaunch).
private struct RefreshOnForegroundModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastPhase: ScenePhase?
    let action: () async -> Void

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { newPhase in
            defer { lastPhase = newPhase }
            guard newPhase == .active, let lastPhase, lastPhase != .active else { return }
            Task { await action() }
        }
    }
}

extension View {
    func refreshOnForeground(_ action: @escaping () async -> Void) -> some View {
        modifier(RefreshOnForegroundModifier(action: action))
    }
}
