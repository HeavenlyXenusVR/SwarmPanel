import Foundation

@MainActor
final class AccountsAdminViewModel: ObservableObject {
    @Published var accounts: [SwarmAccountSummary] = []
    @Published var query = ""
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    // Bulk-selection mode: off by default so the account list behaves
    // exactly as before until the admin explicitly opts into it (see
    // AccountsAdminView's "Select" toolbar button).
    @Published var isSelecting = false
    @Published var selectedIds: Set<Int> = []
    @Published var isBulkWorking = false

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

    func update(_ account: SwarmAccountSummary, username: String, displayName: String, email: String, guildId: String, serverName: String, publicProfile: Bool) async {
        do {
            let _: SwarmAccountUpdateResponse = try await api.post(
                "/api/swarm-accounts/update",
                body: SwarmAccountUpdateBody(
                    accountId: account.id, username: username, displayName: displayName,
                    email: email, guildId: guildId, serverName: serverName, publicProfile: publicProfile
                )
            )
            statusMessage = "\(username) updated."
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to update account."
        }
    }

    func delete(_ account: SwarmAccountSummary) async {
        do {
            let _: OKResponse = try await api.post("/api/swarm-accounts/delete", body: SwarmAccountDeleteBody(accountId: account.id))
            Haptics.warning()
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to delete account."
            Haptics.error()
        }
    }

    func resendVerification(_ account: SwarmAccountSummary) async {
        do {
            let response: SwarmAccountResendVerificationResponse = try await api.post(
                "/api/swarm-accounts/resend-verification",
                body: SwarmAccountResendVerificationBody(accountId: account.id)
            )
            if response.alreadyVerified == true {
                statusMessage = "\(account.username) is already verified."
            } else if response.verificationSent == true {
                statusMessage = "Verification code sent to \(account.username)."
            } else {
                errorMessage = "Could not send a verification code to \(account.username)."
            }
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to resend verification."
        }
    }

    func toggleSelection(_ id: Int) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }

    func exitSelectionMode() {
        isSelecting = false
        selectedIds.removeAll()
    }

    /// Shared summary line for the result toast — "12 succeeded, 1 failed" or
    /// just "12 succeeded" when nothing failed.
    private func summarize(_ result: SwarmAccountBulkResult) -> String {
        let ok = result.succeeded?.count ?? 0
        let failed = result.failed?.count ?? 0
        return failed > 0 ? "\(ok) succeeded, \(failed) failed." : "\(ok) succeeded."
    }

    func bulkVerify(_ verified: Bool) async {
        guard !selectedIds.isEmpty else { return }
        isBulkWorking = true
        defer { isBulkWorking = false }
        do {
            let result: SwarmAccountBulkResult = try await api.post(
                "/api/swarm-accounts/bulk-verify",
                body: SwarmAccountBulkVerifyBody(ids: Array(selectedIds), verified: verified)
            )
            statusMessage = "Bulk \(verified ? "verify" : "unverify"): \(summarize(result))"
            exitSelectionMode()
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Bulk verify failed."
        }
    }

    func bulkDelete() async {
        guard !selectedIds.isEmpty else { return }
        isBulkWorking = true
        defer { isBulkWorking = false }
        do {
            let result: SwarmAccountBulkResult = try await api.post(
                "/api/swarm-accounts/bulk-delete",
                body: SwarmAccountBulkIdsBody(ids: Array(selectedIds))
            )
            Haptics.warning()
            statusMessage = "Bulk delete: \(summarize(result))"
            exitSelectionMode()
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Bulk delete failed."
            Haptics.error()
        }
    }
}
