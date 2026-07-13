import Foundation

/// GET /api/swarm-accounts/admin returns {"ok": true, "data": {"summary":
/// {...}, "users": [...], "query": ..., "limit": ...}} — owner-only.
struct SwarmAccountsAdminEnvelope: Decodable {
    let data: SwarmAccountsAdminData
}

struct SwarmAccountsAdminData: Decodable {
    let users: [SwarmAccountSummary]?
}

struct SwarmAccountSummary: Decodable, Identifiable {
    let id: Int
    let username: String
    let guildId: String?
    let displayName: String?
    let email: String?
    let verificationVerified: Bool?
    let publicProfile: Bool?
    let panelRole: String?

    var name: String { displayName?.isEmpty == false ? displayName! : username }
    var isModerator: Bool { panelRole == "moderator" }
}

struct SwarmAccountFlagBody: Encodable {
    let accountId: Int
    let verified: Bool
}

struct SwarmAccountPasswordResetBody: Encodable {
    let accountId: Int
    let newPassword: String
}

struct SwarmAccountDeleteBody: Encodable {
    let accountId: Int
}

struct SwarmAccountModeratorBody: Encodable {
    let accountId: Int
    let moderator: Bool
}
