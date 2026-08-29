import Foundation

@MainActor
final class GalleryModerationViewModel: ObservableObject {
    @Published var comments: [GalleryComment] = []
    @Published var reports: [GalleryReport] = []
    // Previously undecoded/unused entirely -- see the matching note on
    // GalleryAdminData. Media moderation and user management (verify,
    // reset password, delete, bulk actions) had no iOS UI at all before
    // this; the web panel's Gallery Admin has always had both.
    @Published var media: [GalleryMedia] = []
    @Published var users: [GalleryUser] = []
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var selectedCommentIds: Set<Int> = []
    @Published var selectedMediaIds: Set<Int> = []
    @Published var selectedUserIds: Set<Int> = []
    @Published var isBulkDeleting = false
    @Published var isExporting = false

    private let api = APIClient.shared

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let envelope: GalleryAdminEnvelope = try await api.get("/api/image-gallery/admin", query: ["limit": "50"])
            comments = envelope.data.comments ?? []
            reports = envelope.data.reports ?? []
            media = envelope.data.media ?? []
            users = envelope.data.users ?? []
            errorMessage = nil
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load gallery admin data."
        }
    }

    // MARK: - Comments (unchanged)

    func deleteComment(_ comment: GalleryComment) async {
        do {
            let _: OKResponse = try await api.post("/api/image-gallery/comments/delete", body: GalleryCommentDeleteBody(commentId: comment.id))
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to delete comment."
        }
    }

    func toggleSelection(_ comment: GalleryComment) {
        if selectedCommentIds.contains(comment.id) {
            selectedCommentIds.remove(comment.id)
        } else {
            selectedCommentIds.insert(comment.id)
        }
    }

    func bulkDeleteSelectedComments() async {
        guard !selectedCommentIds.isEmpty else { return }
        isBulkDeleting = true
        defer { isBulkDeleting = false }
        do {
            let _: OKResponse = try await api.post(
                "/api/image-gallery/admin/comments/bulk-delete",
                body: GalleryBulkDeleteBody(ids: Array(selectedCommentIds))
            )
            selectedCommentIds.removeAll()
            Haptics.success()
            await load()
        } catch {
            guard !error.isCancellation else { return }
            Haptics.error()
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to delete comments."
        }
    }

    func setReportStatus(_ report: GalleryReport, status: String) async {
        do {
            let _: OKResponse = try await api.post("/api/image-gallery/reports/status", body: GalleryReportStatusBody(reportId: report.id, status: status))
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to update report."
        }
    }

    // MARK: - Media

    func setModerationStatus(_ item: GalleryMedia, status: String) async {
        do {
            let _: OKResponse = try await api.post(
                "/api/image-gallery/media/update",
                body: GalleryMediaUpdateBody(mediaId: item.id, moderationStatus: status, moderationReason: nil, isAdult: nil)
            )
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to update media."
        }
    }

    func toggleAdult(_ item: GalleryMedia) async {
        do {
            let _: OKResponse = try await api.post(
                "/api/image-gallery/media/update",
                body: GalleryMediaUpdateBody(mediaId: item.id, moderationStatus: nil, moderationReason: nil, isAdult: !(item.isAdult ?? false))
            )
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to update media."
        }
    }

    func deleteMedia(_ item: GalleryMedia) async {
        do {
            let _: OKResponse = try await api.post("/api/image-gallery/media/delete", body: GalleryMediaDeleteBody(mediaId: item.id))
            Haptics.warning()
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to delete media."
            Haptics.error()
        }
    }

    func toggleMediaSelection(_ item: GalleryMedia) {
        if selectedMediaIds.contains(item.id) { selectedMediaIds.remove(item.id) } else { selectedMediaIds.insert(item.id) }
    }

    func bulkDeleteSelectedMedia() async {
        guard !selectedMediaIds.isEmpty else { return }
        isBulkDeleting = true
        defer { isBulkDeleting = false }
        do {
            let _: OKResponse = try await api.post(
                "/api/image-gallery/admin/media/bulk-delete",
                body: GalleryBulkDeleteBody(ids: Array(selectedMediaIds))
            )
            selectedMediaIds.removeAll()
            Haptics.success()
            await load()
        } catch {
            guard !error.isCancellation else { return }
            Haptics.error()
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to delete media."
        }
    }

    // MARK: - Users

    func toggleEmailVerified(_ user: GalleryUser) async {
        do {
            let _: OKResponse = try await api.post(
                "/api/image-gallery/users/email-verified",
                body: GalleryUserFlagBody(userId: user.id, verified: !user.isEmailVerified)
            )
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to update verification."
        }
    }

    func toggleAgeVerified(_ user: GalleryUser) async {
        do {
            let _: OKResponse = try await api.post(
                "/api/image-gallery/users/age-verified",
                body: GalleryUserFlagBody(userId: user.id, verified: !user.isAgeVerified)
            )
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to update age verification."
        }
    }

    func resendVerification(_ user: GalleryUser) async {
        do {
            let response: GalleryUserResendVerificationResponse = try await api.post(
                "/api/image-gallery/users/resend-verification",
                body: GalleryUserResendVerificationBody(userId: user.id)
            )
            if response.alreadyVerified == true {
                statusMessage = "\(user.username) is already verified."
            } else if response.emailVerificationSent == true {
                statusMessage = "Verification email sent to \(user.username)."
            } else {
                errorMessage = "Could not send a verification email to \(user.username)."
            }
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to resend verification."
        }
    }

    func resetPassword(_ user: GalleryUser, newPassword: String) async {
        do {
            let _: OKResponse = try await api.post(
                "/api/image-gallery/users/reset-password",
                body: GalleryUserResetPasswordBody(userId: user.id, newPassword: newPassword)
            )
            statusMessage = "Password reset for \(user.username)."
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to reset password."
        }
    }

    func update(_ user: GalleryUser, username: String, displayName: String, email: String, publicProfile: Bool) async {
        do {
            let _: OKResponse = try await api.post(
                "/api/image-gallery/users/update",
                body: GalleryUserUpdateBody(userId: user.id, username: username, displayName: displayName, email: email, publicProfile: publicProfile)
            )
            statusMessage = "\(username) updated."
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to update user."
        }
    }

    func deleteUser(_ user: GalleryUser) async {
        do {
            let _: OKResponse = try await api.post("/api/image-gallery/users/delete", body: GalleryUserDeleteBody(userId: user.id))
            Haptics.warning()
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to delete user."
            Haptics.error()
        }
    }

    func toggleUserSelection(_ user: GalleryUser) {
        if selectedUserIds.contains(user.id) { selectedUserIds.remove(user.id) } else { selectedUserIds.insert(user.id) }
    }

    func bulkDeleteSelectedUsers() async {
        guard !selectedUserIds.isEmpty else { return }
        isBulkDeleting = true
        defer { isBulkDeleting = false }
        do {
            let _: OKResponse = try await api.post(
                "/api/image-gallery/admin/users/bulk-delete",
                body: GalleryBulkDeleteBody(ids: Array(selectedUserIds))
            )
            selectedUserIds.removeAll()
            Haptics.success()
            await load()
        } catch {
            guard !error.isCancellation else { return }
            Haptics.error()
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to delete users."
        }
    }

    // MARK: - CSV exports

    func exportMediaCSV() async -> URL? {
        await downloadCSV(path: "/api/image-gallery/admin/media/export.csv", filename: "gallery_media.csv")
    }

    func exportUsersCSV() async -> URL? {
        await downloadCSV(path: "/api/image-gallery/admin/users/export.csv", filename: "gallery_users.csv")
    }

    private func downloadCSV(path: String, filename: String) async -> URL? {
        isExporting = true
        defer { isExporting = false }
        do {
            let data = try await api.downloadRaw(path)
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try data.write(to: tempURL, options: .atomic)
            return tempURL
        } catch {
            guard !error.isCancellation else { return nil }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to export CSV."
            return nil
        }
    }
}
