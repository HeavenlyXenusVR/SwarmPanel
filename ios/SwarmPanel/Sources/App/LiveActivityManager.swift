import ActivityKit
import Foundation

/// Starts/updates/ends the Lock Screen + Dynamic Island Live Activity for
/// the account's own guild's Now Playing session. Purely local — no push
/// updates (pushType: nil) — since this app has no paid Apple Developer
/// account for the APNs entitlement a push-driven Live Activity would need.
/// Driven by the same call site that feeds WidgetDataService, so playback
/// state is only computed once per change.
@available(iOS 16.1, *)
@MainActor
enum LiveActivityManager {
    private static var activity: Activity<SwarmPanelActivityAttributes>?

    static func update(title: String, subtitle: String, isPlaying: Bool, isPaused: Bool, position: TimeInterval, duration: TimeInterval) {
        guard !title.isEmpty else {
            end()
            return
        }
        let state = SwarmPanelActivityAttributes.ContentState(
            title: title, subtitle: subtitle, isPlaying: isPlaying, isPaused: isPaused,
            position: position, duration: duration, anchorDate: Date()
        )

        if let activity {
            Task { await activity.update(using: state) }
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity<SwarmPanelActivityAttributes>.request(
                attributes: SwarmPanelActivityAttributes(),
                contentState: state,
                pushType: nil
            )
        } catch {
            // Best-effort — Live Activities are a nice-to-have, not required for the app to function.
        }
    }

    static func end() {
        guard let activity else { return }
        let finalState = SwarmPanelActivityAttributes.ContentState(
            title: "", subtitle: "", isPlaying: false, isPaused: false,
            position: 0, duration: 0, anchorDate: Date()
        )
        Task { await activity.end(using: finalState, dismissalPolicy: .immediate) }
        self.activity = nil
    }
}
