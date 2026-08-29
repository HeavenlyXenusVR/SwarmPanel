import Foundation

/// GET /api/users/me returns {"editable": bool, "profile": {...}} (no "ok"
/// wrapper, unlike most other endpoints — see app/routers/users.py).
struct MeResponse: Decodable {
    let editable: Bool?
    let profile: MeProfile
}

/// POST /api/users/me returns {"ok": true, "profile": {...}}.
struct MeProfileEnvelope: Decodable {
    let profile: MeProfile
}

struct MeProfile: Decodable {
    let username: String?
    let displayName: String?
    let bio: String?
    let publicProfile: Bool?
    let themeAccent: String?
    let serverName: String?
    /// Decode-only (not part of ProfileUpdateBody -- this screen doesn't
    /// edit either) -- backs the Getting Started checklist below.
    let verificationVerified: Bool?
    let avatarUrl: String?
    /// Decode-only, all consumed by AccountSecurityView/ViewModel (not the
    /// profile-editing form above) -- account email + verification status,
    /// mirroring web's ProfilePage.jsx Account/Verification panels.
    let email: String?
    let hasPassword: Bool?
    let verificationPending: Bool?
    let verificationWebhookUrl: String?
    let discordUserId: String?
}

/// POST /api/session/password body -- current_password/new_password.
struct PasswordChangeBody: Encodable {
    let currentPassword: String
    let newPassword: String
}

/// POST /api/session/email body.
struct EmailChangeBody: Encodable {
    let email: String
}

/// POST /api/session/verification-webhook body.
struct VerificationWebhookBody: Encodable {
    let verificationWebhookUrl: String
}

/// POST /api/session/verification-discord body.
struct VerificationDiscordBody: Encodable {
    let discordUserId: String
}

/// POST /api/session/verification/verify body.
struct VerificationCodeBody: Encodable {
    let code: String
}

/// Shared response shape for verification-webhook/verification-discord:
/// {"ok": true, "profile": {...}, "verification_sent": bool}.
struct VerificationSendResponse: Decodable {
    let profile: MeProfile
    let verificationSent: Bool?
}

/// POST /api/session/resend-verification response --
/// {"ok": true, "verification_sent": bool, "already_verified": bool}.
struct ResendVerificationResponse: Decodable {
    let verificationSent: Bool?
    let alreadyVerified: Bool?
}

/// Only the fields this app's Profile/Appearance screen edits — the full
/// UserProfileUpdateRequest schema has many more web-only fields (banners,
/// card styles, layout modes) that don't apply to a native UI.
struct ProfileUpdateBody: Encodable {
    let displayName: String?
    let bio: String?
    let publicProfile: Bool?
    let themeAccent: String?
}
