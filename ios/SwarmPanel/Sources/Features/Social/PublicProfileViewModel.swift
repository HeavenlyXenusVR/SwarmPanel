import Foundation

@MainActor
final class PublicProfileViewModel: ObservableObject {
    @Published var profile: PublicProfile?
    @Published var permissions: SocialPermissions?
    @Published var isLoading = true
    @Published var isActing = false
    @Published var errorMessage: String?

    private let api = APIClient.shared
    let accountId: Int

    init(accountId: Int) {
        self.accountId = accountId
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let envelope: PublicProfileEnvelope = try await api.get("/api/users/\(accountId)/profile")
            profile = envelope.profile
            permissions = envelope.socialPermissions
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load profile."
        }
    }

    func toggleFollow() async {
        guard let profile else { return }
        isActing = true
        defer { isActing = false }
        do {
            let _: OKResponse = try await api.post(
                "/api/users/\(accountId)/follow",
                body: FollowBody(following: !(profile.followedByMe ?? false))
            )
            Haptics.success()
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to update follow."
            Haptics.error()
        }
    }

    func sendFriendRequest() async {
        isActing = true
        defer { isActing = false }
        do {
            let _: OKResponse = try await api.post("/api/users/\(accountId)/friend-request")
            Haptics.success()
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to send friend request."
            Haptics.error()
        }
    }
}
