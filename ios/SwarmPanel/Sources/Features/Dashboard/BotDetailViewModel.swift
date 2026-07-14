import Foundation

@MainActor
final class BotDetailViewModel: ObservableObject {
    @Published var session: ControlStateSession?
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var isSending = false

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

    /// Shared by the loop/filter quick-set pickers and "Queue This" — all three
    /// reuse the same POST /api/bots/control endpoint Controls already covers,
    /// just triggered inline here instead of navigating away. Reloads control
    /// state afterward so the picker/labels reflect the change immediately.
    @discardableResult
    func sendAction(botKey: String, guildId: String, action: String, payload: [String: String] = [:]) async -> Bool {
        isSending = true
        defer { isSending = false }
        do {
            let _: OKResponse = try await api.post(
                "/api/bots/control",
                body: BotControlRequest(botKey: botKey, guildId: guildId, action: action, payload: payload)
            )
            await load(botKey: botKey, guildId: guildId)
            return true
        } catch {
            guard !error.isCancellation else { return false }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Action failed."
            return false
        }
    }
}
