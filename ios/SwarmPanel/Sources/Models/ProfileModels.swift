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
