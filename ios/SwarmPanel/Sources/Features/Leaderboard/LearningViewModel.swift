import Foundation

@MainActor
final class LearningViewModel: ObservableObject {
    @Published var data: MusicIntelligenceData?
    @Published var isLoading = true
    @Published var errorMessage: String?

    private let api = APIClient.shared

    /// guildId nil/empty means fleet-wide for an admin (the server rejects
    /// it for a non-admin with no guild — surfaced as errorMessage, same
    /// defense-in-depth pattern LeaderboardViewModel's swarm call uses).
    func load(guildId: String?) async {
        isLoading = true
        defer { isLoading = false }
        do {
            var query: [String: String?] = [:]
            if let guildId, !guildId.isEmpty { query["guild_id"] = guildId }
            let envelope: MusicIntelligenceEnvelope = try await api.get("/api/music-intelligence", query: query)
            data = envelope.data
            errorMessage = nil
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load music intelligence."
        }
    }
}
