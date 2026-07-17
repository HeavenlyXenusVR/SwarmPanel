import Foundation

/// A guild being served by more than one bot at once — surfaced explicitly
/// because this is exactly the situation that gave two different
/// `DashboardSession`s the same `guildId:channelId` identity and crashed
/// Dashboard's Live Sessions list before that view started keying identity
/// on the owning bot too. Not a bug here, just something admins should be
/// able to see at a glance rather than discover by accident.
struct GuildOverlap: Identifiable {
    let guildId: String
    let guildLabel: String
    let botLabels: [String]
    var id: String { guildId }
}

@MainActor
final class FleetTopologyViewModel: ObservableObject {
    @Published var bots: [DashboardBot] = []
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var restartingBotKey: String?

    private let api = APIClient.shared

    var overlaps: [GuildOverlap] {
        var byGuild: [String: [(bot: String, label: String)]] = [:]
        for bot in bots {
            let botLabel = bot.displayName?.isEmpty == false ? bot.displayName! : bot.key
            for session in bot.sessions ?? [] {
                guard let guildId = session.guildId else { continue }
                let label = session.guildName ?? "Guild \(guildId)"
                byGuild[guildId, default: []].append((bot: botLabel, label: label))
            }
        }
        return byGuild.compactMap { guildId, entries in
            let uniqueBots = Array(Set(entries.map { $0.bot })).sorted()
            guard uniqueBots.count > 1 else { return nil }
            return GuildOverlap(guildId: guildId, guildLabel: entries.first?.label ?? "Guild \(guildId)", botLabels: uniqueBots)
        }.sorted { $0.guildLabel < $1.guildLabel }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: DashboardResponse = try await api.get("/api/dashboard")
            bots = response.bots ?? []
            errorMessage = nil
        } catch {
            if !error.isCancellation {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load fleet topology."
            }
        }
    }

    /// RESTART is process-wide, not per-guild — the backend fixes guild_id
    /// to "0" for this action regardless of what's sent (app/routers/bots.py's
    /// _normalize_bot_control_request), and rejects it outright for
    /// guild-scoped (non-admin) accounts.
    func restart(_ bot: DashboardBot) async {
        restartingBotKey = bot.key
        defer { restartingBotKey = nil }
        do {
            let _: OKResponse = try await api.post(
                "/api/bots/control",
                body: BotControlRequest(botKey: bot.key, guildId: "0", action: "RESTART", payload: [:])
            )
            Haptics.success()
            statusMessage = "Restart sent to \(bot.displayName?.isEmpty == false ? bot.displayName! : bot.key)."
            await load()
        } catch {
            if !error.isCancellation {
                Haptics.error()
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Restart failed."
            }
        }
    }
}
