import Foundation

@MainActor
final class LeaderboardViewModel: ObservableObject {
    @Published var bots: [BotSummary] = []
    @Published var selectedBotKey: String = ""
    @Published var guildId: String = ""
    @Published var data: LeaderboardData?
    @Published var isLoading = true
    @Published var errorMessage: String?

    private let api = APIClient.shared

    func loadBots() async {
        do {
            let response: BotsResponse = try await api.get("/api/bots")
            bots = (response.bots ?? []).filter { $0.kind == "music" }
            if selectedBotKey.isEmpty { selectedBotKey = bots.first?.id ?? "" }
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load bots."
        }
    }

    func loadLeaderboard() async {
        guard !selectedBotKey.isEmpty, !guildId.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let envelope: LeaderboardEnvelope = try await api.get(
                "/api/guilds/\(guildId)/leaderboard",
                query: ["bot_key": selectedBotKey]
            )
            data = envelope.data
            errorMessage = nil
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load leaderboard."
        }
    }
}
