import Foundation

@MainActor
final class GalleryModerationViewModel: ObservableObject {
    @Published var comments: [GalleryComment] = []
    @Published var reports: [GalleryReport] = []
    @Published var isLoading = true
    @Published var errorMessage: String?

    private let api = APIClient.shared

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let envelope: GalleryAdminEnvelope = try await api.get("/api/image-gallery/admin", query: ["limit": "50"])
            comments = envelope.data.comments ?? []
            reports = envelope.data.reports ?? []
            errorMessage = nil
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load gallery admin data."
        }
    }

    func deleteComment(_ comment: GalleryComment) async {
        do {
            let _: OKResponse = try await api.post("/api/image-gallery/comments/delete", body: GalleryCommentDeleteBody(commentId: comment.id))
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to delete comment."
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
}
