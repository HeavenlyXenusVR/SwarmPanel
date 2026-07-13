import Foundation

/// Mirrors GET /api/guilds/{id}/leaderboard's {"ok": true, "data": {...}}
/// envelope (app/routers/bots.py, app/db/bots.py's get_guild_leaderboard).
struct LeaderboardEnvelope: Decodable {
    let data: LeaderboardData
}

struct LeaderboardData: Decodable {
    let topTracks: [LeaderboardTrack]?
    let topListeners: [LeaderboardListener]?
}

struct LeaderboardTrack: Decodable, Identifiable {
    let title: String?
    let videoUrl: String?
    let playCount: Int?
    let likeCount: Int?
    let dislikeCount: Int?

    var id: String { videoUrl ?? title ?? UUID().uuidString }
}

struct LeaderboardListener: Decodable, Identifiable {
    let userId: Int64?
    let trackCount: Int?
    let playCount: Int?

    var id: String { userId.map(String.init) ?? UUID().uuidString }
}
