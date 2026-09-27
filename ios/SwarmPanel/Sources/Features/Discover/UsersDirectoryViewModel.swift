import Foundation

@MainActor
final class UsersDirectoryViewModel: ObservableObject {
    @Published var query = ""
    /// Only operators seen in the last 3 minutes (?online=1), matching the
    /// web Directory's "Online now" toggle.
    @Published var onlineOnly = false
    @Published var users: [AccountSummary] = []
    @Published var isLoading = true
    @Published var errorMessage: String?

    private let api = APIClient.shared

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: UserSearchResponse = try await api.get(
                "/api/users/directory",
                query: ["q": query, "online": onlineOnly ? "1" : nil]
            )
            users = response.users ?? []
            errorMessage = nil
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load the directory."
        }
    }

    func follow(_ accountId: Int, following: Bool) async {
        do {
            let _: OKResponse = try await api.post("/api/users/\(accountId)/follow", body: FollowBody(following: following))
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Follow failed."
        }
    }
}
