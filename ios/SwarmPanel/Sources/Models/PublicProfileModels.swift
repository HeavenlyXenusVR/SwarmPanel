import Foundation

/// GET /api/users/:account_id/profile — never called anywhere in the app
/// before this; every user-tap anywhere (Directory, Friends, Social search)
/// only ever offered Message/Follow/Friend-request, with no way to actually
/// see the other person's profile (bio, banner, tags, activity, links).
struct PublicProfileEnvelope: Decodable {
    let profile: PublicProfile
    let socialPermissions: SocialPermissions?
}

struct SocialPermissions: Decodable {
    let canFriend: Bool?
    let canMessage: Bool?
    let canFollow: Bool?
}

struct PublicProfile: Decodable {
    let id: Int
    let username: String
    let displayName: String?
    let bio: String?
    let profileQuote: String?
    let profileHeadline: String?
    let avatarUrl: String?
    let themeAccent: String?
    let isOnline: Bool?
    let favoriteBot: String?
    let serverName: String?
    let serverInviteUrl: String?
    let guildId: String?
    let profileTags: [String]?
    let profileLinks: [ProfileLink]?
    let followerCount: Int?
    let followingCount: Int?
    let friendCount: Int?
    /// "self" | "friends" | "pending_out" | "pending_in" | nil (strangers)
    let friendStatus: String?
    /// A proper JSON bool on this endpoint (unlike AccountSummary's
    /// directory-listing 0/1-int version of the same field — see the note
    /// on AccountSummary.followedByMe).
    let followedByMe: Bool?
    let activity: PublicProfileActivity?

    var name: String { displayName?.isEmpty == false ? displayName! : username }
}

struct ProfileLink: Decodable, Identifiable {
    let label: String
    let url: String
    var id: String { url }
}

struct PublicProfileActivity: Decodable {
    let totalPlays: Int?
    let topTracks: [PublicProfileTrack]?
    let activeSessions: [PublicProfileSession]?
}

struct PublicProfileTrack: Decodable, Identifiable {
    let title: String?
    let videoUrl: String?
    let plays: Int?
    var id: String { videoUrl ?? title ?? UUID().uuidString }
}

struct PublicProfileSession: Decodable, Identifiable {
    let title: String?
    let botDisplay: String?
    let isPlaying: Bool?
    var id: String { (botDisplay ?? "") + (title ?? "") }
}
