import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Shared between the SwarmPanel app target and the SwarmPanelWidget
/// extension target (both list this file in project.yml) so the two
/// processes agree on the App Group's storage keys and the Live Activity's
/// data shape without needing a separate framework target.
enum WidgetShared {
    static let appGroupID = "group.com.swarmpanel.ios"
    static let thumbnailFilename = "widget_thumbnail.jpg"

    enum Keys {
        static let title = "widget_session_title"
        static let subtitle = "widget_session_subtitle"
        static let isPlaying = "widget_is_playing"
        static let isPaused = "widget_is_paused"
        static let position = "widget_position"
        static let duration = "widget_duration"
        static let anchorDate = "widget_anchor_date"
        static let thumbnailPath = "widget_thumbnail_path"
        static let botsCount = "widget_bots_count"
        static let liveCount = "widget_live_count"
        static let queuedCount = "widget_queued_count"
    }
}

/// Own-guild Now Playing state for the Lock Screen / Dynamic Island Live
/// Activity — purely local (pushType: nil when requested), since this app
/// has no paid Apple Developer account for the APNs entitlement a
/// push-driven Live Activity would need.
@available(iOS 16.1, *)
struct SwarmPanelActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var subtitle: String
        var isPlaying: Bool
        var isPaused: Bool
        var position: TimeInterval
        var duration: TimeInterval
        /// The moment `position`/`isPlaying` were captured — lets
        /// `Text(timerInterval:)` keep ticking between updates.
        var anchorDate: Date

        var trackRange: ClosedRange<Date> {
            let start = anchorDate.addingTimeInterval(-position)
            let end = start.addingTimeInterval(max(duration, position))
            return start...max(start, end)
        }
    }
}
