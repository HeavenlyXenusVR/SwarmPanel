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
    let serverName: String?

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

/// POST /api/swarm-accounts/update — omitted fields are left untouched
/// server-side (routes.lua only applies keys present in the JSON body).
struct SwarmAccountUpdateBody: Encodable {
    let accountId: Int
    let username: String
    let displayName: String
    let email: String
    let guildId: String
    let serverName: String
    let publicProfile: Bool
}

struct SwarmAccountUpdateResponse: Decodable {
    let ok: Bool?
    let account: SwarmAccountSummary?
}

struct SwarmAccountModeratorBody: Encodable {
    let accountId: Int
    let moderator: Bool
}

struct SwarmAccountResendVerificationBody: Encodable {
    let accountId: Int
}

struct SwarmAccountResendVerificationResponse: Decodable {
    let ok: Bool?
    let verificationSent: Bool?
    let alreadyVerified: Bool?
}

struct SwarmAccountBulkIdsBody: Encodable {
    let ids: [Int]
}

struct SwarmAccountBulkVerifyBody: Encodable {
    let ids: [Int]
    let verified: Bool
}

/// Shared response shape for both bulk-delete and bulk-verify — routes.lua's
/// run_bulk_op() returns the same {ok, succeeded: [ids], failed: [{id,
/// error}]} for both.
struct SwarmAccountBulkResult: Decodable {
    let ok: Bool?
    let succeeded: [Int]?
    let failed: [SwarmAccountBulkFailure]?
}

struct SwarmAccountBulkFailure: Decodable, Identifiable {
    let id: Int
    let error: String?
}
