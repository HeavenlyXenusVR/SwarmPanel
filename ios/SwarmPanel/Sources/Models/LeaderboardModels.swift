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

/// Mirrors GET /api/swarm-leaderboard (admin-only) — dashboard.lua's
/// get_swarm_leaderboard(), which fans out across every bot's own Postgres
/// database rather than a single guild's. No wrapping "data" envelope (this
/// route returns the payload flat, unlike the per-guild one above).
struct SwarmLeaderboardResponse: Decodable {
    let windowDays: Int?
    let generatedAt: String?
    let botsQueried: Int?
    let botsErrored: Int?
    let tracks: [SwarmLeaderboardTrack]?
}

struct SwarmLeaderboardTrack: Decodable, Identifiable {
    let title: String?
    let videoUrl: String?
    let playCount: Int?
    let finishCount: Int?
    let skipCount: Int?
    let likeCount: Int?
    let dislikeCount: Int?
    let smartScore: Int?
    let botKey: String?
    let botDisplay: String?

    var id: String { (botKey ?? "") + (videoUrl ?? title ?? UUID().uuidString) }
}

// MARK: - Music Intelligence (GET /api/music-intelligence) —
// dashboard.get_music_intelligence_summary(): what the swarm's smart-
// recommendation engine has learned (learned-track counts, plays/finishes/
// skips/likes/dislikes totals, recommendation counts, per-bot top tracks by
// smart score). Any account can reach their own guild's data; admins can
// omit guild_id for a fleet-wide view.

struct MusicIntelligenceEnvelope: Decodable {
    let data: MusicIntelligenceData
}

struct MusicIntelligenceData: Decodable {
    let totals: MusicIntelligenceTotals?
    let bots: [MusicIntelligenceBot]?
}

struct MusicIntelligenceTotals: Decodable {
    let learnedTracks: Int?
    let plays: Int?
    let finishes: Int?
    let skips: Int?
    let likes: Int?
    let dislikes: Int?
    let recommendations: Int?
}

struct MusicIntelligenceBot: Decodable, Identifiable {
    let botKey: String?
    let botDisplay: String?
    let learnedTracks: Int?
    let plays: Int?
    let finishes: Int?
    let skips: Int?
    let likes: Int?
    let dislikes: Int?
    let recommendations: Int?
    let topTracks: [MusicIntelligenceTrack]?

    var id: String { botKey ?? UUID().uuidString }
}

struct MusicIntelligenceTrack: Decodable, Identifiable {
    let title: String?
    let videoUrl: String?
    let playCount: Int?
    let finishCount: Int?
    let skipCount: Int?
    let likeCount: Int?
    let smartScore: Int?

    var id: String { videoUrl ?? title ?? UUID().uuidString }
}
