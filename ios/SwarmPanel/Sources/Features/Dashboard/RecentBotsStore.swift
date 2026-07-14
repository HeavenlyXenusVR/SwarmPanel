import Foundation

/// Small client-only "jump back in" list — BotDetailView records a visit,
/// Dashboard renders the last few as tappable chips above Live Sessions.
/// Persisted to UserDefaults (not the account), so it's local to this device.
struct RecentBotVisit: Codable, Identifiable, Equatable {
    let botKey: String
    let guildId: String
    let displayName: String

    var id: String { "\(botKey):\(guildId)" }
}

@MainActor
final class RecentBotsStore: ObservableObject {
    @Published private(set) var visits: [RecentBotVisit] = []

    private static let key = "swarmpanel.recentBotVisits"
    private static let maxEntries = 6

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([RecentBotVisit].self, from: data) {
            visits = decoded
        }
    }

    func record(botKey: String, guildId: String, displayName: String) {
        guard !botKey.isEmpty, !guildId.isEmpty else { return }
        let entry = RecentBotVisit(botKey: botKey, guildId: guildId, displayName: displayName)
        visits.removeAll { $0.id == entry.id }
        visits.insert(entry, at: 0)
        if visits.count > Self.maxEntries { visits.removeLast(visits.count - Self.maxEntries) }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(visits) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
