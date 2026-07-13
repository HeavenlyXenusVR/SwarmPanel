import Foundation

// MARK: - Directory / search (GET /api/users/search, /api/users/directory)

struct UserSearchResponse: Decodable {
    let users: [AccountSummary]?
}

struct AccountSummary: Decodable, Identifiable {
    let id: Int
    let username: String
    let displayName: String?
    let bio: String?
    let serverName: String?
    let isOnline: Bool?

    var name: String { displayName?.isEmpty == false ? displayName! : username }
}

// MARK: - Friend requests (GET /api/friends/requests, POST .../{id})

struct FriendRequestsResponse: Decodable {
    let incoming: [FriendRequest]?
    let outgoing: [FriendRequest]?
}

struct FriendRequest: Decodable, Identifiable {
    let id: Int
    let userId: Int?
    let username: String?
    let displayName: String?
    let status: String?

    var name: String { displayName?.isEmpty == false ? displayName! : (username ?? "Unknown") }
}

struct FriendActionBody: Encodable {
    let action: String
}

// MARK: - Friends (GET /api/me/friends)

struct FriendsResponse: Decodable {
    let friends: [AccountSummary]?
}

// MARK: - Follow / friend-request actions

struct FollowBody: Encodable {
    let following: Bool
}

// MARK: - Messages (GET /api/messages/threads, GET/POST /api/messages/{id})

struct MessageThreadsResponse: Decodable {
    let threads: [MessageThread]?
}

struct MessageThread: Decodable, Identifiable {
    let accountId: Int
    let username: String?
    let displayName: String?
    let lastMessage: String?
    let unreadCount: Int?

    var id: Int { accountId }
    var name: String { displayName?.isEmpty == false ? displayName! : (username ?? "Unknown") }
}

struct MessagesResponse: Decodable {
    let messages: [ChatMessage]?
}

struct ChatMessage: Decodable, Identifiable {
    let id: Int
    let senderAccountId: Int?
    let recipientAccountId: Int?
    let body: String
    let createdAt: String?
}

struct SendMessageBody: Encodable {
    let body: String
}
