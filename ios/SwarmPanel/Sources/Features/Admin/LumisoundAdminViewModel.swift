import Foundation

@MainActor
final class LumisoundAdminViewModel: ObservableObject {
    @Published var users: [LumisoundUser] = []
    @Published var uploads: [LumisoundUpload] = []
    @Published var bugReports: [LumisoundBugReport] = []
    @Published var isLoading = true
    @Published var errorMessage: String?

    private let api = APIClient.shared

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let envelope: LumisoundAdminEnvelope = try await api.get("/api/lumisound/admin", query: ["limit": "50"])
            users = envelope.data.users ?? []
            uploads = envelope.data.uploads ?? []
            bugReports = envelope.data.bugReports ?? []
            errorMessage = nil
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load Lumisound admin data."
        }
    }

    func setUserActive(_ user: LumisoundUser, active: Bool) async {
        do {
            let _: OKResponse = try await api.post("/api/lumisound/users/active", body: LumisoundUserActiveBody(userId: user.id, active: active))
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to update user."
        }
    }

    func deleteUpload(_ upload: LumisoundUpload) async {
        do {
            let _: OKResponse = try await api.post("/api/lumisound/uploads/delete", body: LumisoundUploadDeleteBody(uploadId: upload.id))
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to delete upload."
        }
    }

    func setBugReportStatus(_ report: LumisoundBugReport, status: String) async {
        do {
            let _: OKResponse = try await api.post("/api/lumisound/bug-reports/status", body: LumisoundBugReportStatusBody(reportId: report.id, status: status))
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to update bug report."
        }
    }
}
