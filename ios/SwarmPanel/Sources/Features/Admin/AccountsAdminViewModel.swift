import Foundation

@MainActor
final class AccountsAdminViewModel: ObservableObject {
    @Published var accounts: [SwarmAccountSummary] = []
    @Published var query = ""
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private let api = APIClient.shared

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let envelope: SwarmAccountsAdminEnvelope = try await api.get("/api/swarm-accounts/admin", query: ["query": query, "limit": "100"])
            accounts = envelope.data.users ?? []
            errorMessage = nil
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load accounts."
        }
    }

    func toggleVerified(_ account: SwarmAccountSummary) async {
        do {
            let _: OKResponse = try await api.post(
                "/api/swarm-accounts/email-verified",
                body: SwarmAccountFlagBody(accountId: account.id, verified: !(account.verificationVerified ?? false))
            )
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to update verification."
        }
    }

    func toggleModerator(_ account: SwarmAccountSummary) async {
        do {
            let _: OKResponse = try await api.post(
                "/api/swarm-accounts/moderator",
                body: SwarmAccountModeratorBody(accountId: account.id, moderator: !account.isModerator)
            )
            statusMessage = account.isModerator ? "Moderator access revoked." : "Moderator access granted."
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to update moderator status."
        }
    }

    func resetPassword(_ account: SwarmAccountSummary, newPassword: String) async {
        do {
            let _: OKResponse = try await api.post(
                "/api/swarm-accounts/reset-password",
                body: SwarmAccountPasswordResetBody(accountId: account.id, newPassword: newPassword)
            )
            statusMessage = "Password reset for \(account.username)."
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to reset password."
        }
    }

    func delete(_ account: SwarmAccountSummary) async {
        do {
            let _: OKResponse = try await api.post("/api/swarm-accounts/delete", body: SwarmAccountDeleteBody(accountId: account.id))
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to delete account."
        }
    }
}
