import Foundation

@MainActor
final class InvitesViewModel: ObservableObject {
    @Published var inviteBots: [InviteBot] = []
    @Published var isLoading = true
    @Published var errorMessage: String?

    private let api = APIClient.shared

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: BotsResponse = try await api.get("/api/bots")
            inviteBots = response.inviteBots ?? []
            errorMessage = nil
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load invite roster."
        }
    }
}
