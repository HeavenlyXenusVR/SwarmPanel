import Foundation

struct NotificationsResponse: Decodable {
    let notifications: [PanelNotification]?
}

struct UnreadCountResponse: Decodable {
    let unreadCount: Int?
}

/// Shape of the "notifications" live-push snapshot (routes.lua's
/// SNAPSHOT_BUILDERS.notifications) -- unread count and the recent list
/// bundled together since the web bell renders both from one push.
struct NotificationsSnapshot: Decodable {
    let unreadCount: Int?
    let notifications: [PanelNotification]?
}

struct PanelNotification: Decodable, Identifiable {
    let id: Int
    let kind: String?
    let title: String
    let body: String?
    let linkPath: String?
    let readAt: String?
    let createdAt: String?

    var isUnread: Bool { readAt == nil }
}
