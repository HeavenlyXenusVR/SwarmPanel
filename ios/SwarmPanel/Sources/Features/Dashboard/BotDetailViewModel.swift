import Foundation

@MainActor
final class BotDetailViewModel: ObservableObject {
    @Published var session: ControlStateSession?
    @Published var isLoading = true
    @Published var errorMessage: String?

    private let api = APIClient.shared

    func load(botKey: String, guildId: String) async {
        guard !botKey.isEmpty, !guildId.isEmpty else {
            errorMessage = "Missing bot or guild."
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let response: ControlStateResponse = try await api.get("/api/bots/\(botKey)/control-state", query: ["guild_id": guildId])
            session = response.session
            errorMessage = nil
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load bot detail."
        }
    }
}
