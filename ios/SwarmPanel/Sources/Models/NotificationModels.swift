import Foundation

struct NotificationsResponse: Decodable {
    let notifications: [PanelNotification]?
}

struct UnreadCountResponse: Decodable {
    let unreadCount: Int?
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
