import Foundation

/// Mirrors GET /api/dashboard's response shape (app/dashboard.py's
/// _build_dashboard_payload). Only the fields the app actually renders are
/// declared — Codable ignores extra JSON keys and tolerates missing optional
/// ones, so this stays resilient to backend fields we don't display yet.
struct DashboardResponse: Decodable {
    let bots: [DashboardBot]?
    let sessions: [DashboardSession]?
}

struct DashboardBot: Decodable, Identifiable {
    let key: String
    let displayName: String?
    let kind: String?
    let status: String?
    let heartbeatStatus: String?
    let activePlayingCount: Int?
    let knownGuildCount: Int?
    let queueDepth: Int?
    let backupQueueDepth: Int?
    let sessions: [DashboardSession]?

    var id: String { key }
}

struct DashboardSession: Decodable, Identifiable {
    let guildId: String?
    let channelId: String?
    let guildName: String?
    let channelName: String?
    let title: String?
    let videoUrl: String?
    let isPlaying: Bool?
    let isPaused: Bool?
    let sessionState: String?
    let sessionStateLabel: String?
    let queueCount: Int?
    let backupQueueCount: Int?
    let positionSeconds: Int?
    let durationSeconds: Int?

    var id: String { (guildId ?? "g") + ":" + (channelId ?? "c") }
}

/// Body for POST /api/bots/control (mirrors app/schemas.py's BotControlRequest).
/// `payload` is kept string-valued only — every action currently used by the
/// app (PAUSE/RESUME/SKIP/PLAY) fits that, and it keeps encoding simple.
struct BotControlRequest: Encodable {
    let botKey: String
    let guildId: String
    let action: String
    let payload: [String: String]
}
