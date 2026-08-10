import Foundation

/// Body for POST /api/session/login (mirrors app/schemas.py's SessionLoginRequest).
struct LoginRequest: Encodable {
    let username: String
    let password: String
    let guildId: String?
}

/// Body for POST /api/session/register (mirrors SessionRegisterRequest).
struct RegisterRequest: Encodable {
    let username: String
    let guildId: String
    let password: String
    let email: String?
    let verificationWebhookUrl: String?
    /// Straight-to-account-owner alternative proof: the backend DMs a
    /// verification code to this Discord User ID instead of a webhook when
    /// verificationWebhookUrl is nil/empty and this is set.
    let discordUserId: String?
}

/// Body for POST /api/session/admin-mode.
struct AdminModeRequest: Encodable {
    let enabled: Bool
}

/// Covers the response shape shared by GET /api/session, POST
/// /api/session/login, and POST /api/session/register — all three return a
/// superset/subset of the same fields (see app/routers/session.py), so one
/// permissive model avoids three near-duplicate structs.
struct SessionPayload: Decodable {
    let ok: Bool?
    let authenticated: Bool?
    let token: String?
    let username: String?
    let role: String?
    let guildId: String?
    let accountGuildId: String?
    let siteOwner: Bool?
    let adminMode: Bool?
    let moderator: Bool?
    let imageGalleryOwner: Bool?
    let verificationSent: Bool?
    let pagesPublicUrl: String?
    let expiresIn: Int?
}
