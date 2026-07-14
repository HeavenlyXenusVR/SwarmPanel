import Foundation

/// User-curated favorites — unlike RecentBotsStore's auto-evicting "jump
/// back in" list, entries here only change when the user explicitly taps
/// the pin toolbar button in BotDetailView. Shown as a permanent section
/// on Dashboard above Recently Viewed. Persisted to UserDefaults, local to
/// this device only.
struct PinnedBot: Codable, Identifiable, Equatable {
    let botKey: String
    let guildId: String
    let displayName: String

    var id: String { "\(botKey):\(guildId)" }
}

@MainActor
final class PinnedBotsStore: ObservableObject {
    @Published private(set) var pinned: [PinnedBot] = []

    private static let key = "swarmpanel.pinnedBots"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([PinnedBot].self, from: data) {
            pinned = decoded
        }
    }

    func isPinned(botKey: String, guildId: String) -> Bool {
        pinned.contains { $0.botKey == botKey && $0.guildId == guildId }
    }

    func toggle(botKey: String, guildId: String, displayName: String) {
        guard !botKey.isEmpty, !guildId.isEmpty else { return }
        if isPinned(botKey: botKey, guildId: guildId) {
            pinned.removeAll { $0.botKey == botKey && $0.guildId == guildId }
        } else {
            pinned.append(PinnedBot(botKey: botKey, guildId: guildId, displayName: displayName))
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(pinned) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
