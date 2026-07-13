import Foundation

// MARK: - Bot roster (GET /api/bots)

struct BotsResponse: Decodable {
    let bots: [BotSummary]?
}

struct BotSummary: Decodable, Identifiable, Hashable {
    let key: String
    let displayName: String?
    let kind: String?

    var id: String { key }
    var label: String { displayName?.isEmpty == false ? displayName! : key }
}

// MARK: - Inventory (GET /api/bots/{key}/inventory)

struct BotInventoryResponse: Decodable {
    let guilds: [InventoryGuild]?
}

struct InventoryGuild: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let channels: [InventoryChannel]?
}

struct InventoryChannel: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let type: Int?

    /// Discord channel type codes, matching frontend/src/pages/ControlsPage.jsx's
    /// voice/text filters (2/13 = voice, 0/5/10/11/12 = text).
    var isVoice: Bool { [2, 13].contains(type ?? -1) }
}

// MARK: - Control state (GET /api/bots/{key}/control-state)

struct ControlStateResponse: Decodable {
    let session: ControlStateSession?
}

struct ControlStateSession: Decodable {
    let title: String?
    let isPlaying: Bool?
    let isPaused: Bool?
    let sessionStateLabel: String?
    let queueCount: Int?
    let queuePreview: [QueueItem]?
    let backupQueueCount: Int?
    let homeChannelId: String?
    let channelId: String?
    let loopMode: String?
    let filterMode: String?
}

struct QueueItem: Codable, Hashable {
    let videoUrl: String
    let title: String?
}

// MARK: - Saved queues (GET/POST /api/queues, POST /api/queues/{id}/delete)

struct SavedQueuesResponse: Decodable {
    let queues: [SavedQueue]?
}

struct SavedQueue: Decodable, Identifiable {
    let id: Int
    let name: String
    let items: [QueueItem]?

    var itemCount: Int { items?.count ?? 0 }
}

/// POST /api/queues returns {"ok": true, "queue": {...}} — a thin envelope,
/// unlike GET /api/queues which returns {"ok": true, "queues": [...]} directly
/// matched by SavedQueuesResponse above.
struct SavedQueueEnvelope: Decodable {
    let queue: SavedQueue
}

struct SavedQueueCreateBody: Encodable {
    let guildId: String
    let botKey: String
    let name: String
    let items: [QueueItem]
}

struct SavedQueueDeleteBody: Encodable {
    let guildId: String
}

// MARK: - Control actions

enum ControlAction: String, CaseIterable, Identifiable {
    case play = "PLAY"
    case smartRecommend = "SMART_RECOMMEND"
    case pause = "PAUSE"
    case resume = "RESUME"
    case skip = "SKIP"
    case stop = "STOP"
    case clear = "CLEAR"
    case shuffle = "SHUFFLE"
    case loop = "LOOP"
    case filter = "FILTER"
    case leave = "LEAVE"
    case setHome = "SET_HOME"
    case recover = "RECOVER"
    // RESTART intentionally excluded — owner/admin-only on the web too.

    var id: String { rawValue }
    var label: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
    var needsVoiceChannel: Bool { [.play, .setHome, .smartRecommend].contains(self) }
    var needsSourceURL: Bool { self == .play }
    var needsLoopMode: Bool { self == .loop }
    var needsFilterMode: Bool { self == .filter }
}

let loopModes = ["off", "song", "queue"]
let filterModes = [
    "none", "nightcore", "bassboost", "vaporwave", "8d", "karaoke",
    "tremolo", "vibrato", "lowpass", "lofi", "electronic", "party", "radio", "cinema",
]
