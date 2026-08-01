import Foundation

@MainActor
final class AuditLogViewModel: ObservableObject {
    @Published var entries: [AuditLogEntry] = []
    @Published var total = 0
    @Published var actionFilter = ""
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var revertingId: Int?

    private let api = APIClient.shared

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let envelope: AuditLogEnvelope = try await api.get(
                "/api/audit-log",
                query: ["limit": "100", "action": actionFilter.isEmpty ? nil : actionFilter]
            )
            entries = envelope.data.entries ?? []
            total = envelope.data.total ?? entries.count
            errorMessage = nil
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load audit log."
        }
    }

    /// Not every entry is revertible — routes.lua's REVERTIBLE_ACTIONS table
    /// gates this server-side (and requires a recorded before-state on the
    /// entry), so the client doesn't try to precompute eligibility and just
    /// surfaces whatever 400 message comes back for an entry that can't be
    /// reverted.
    func revert(_ entry: AuditLogEntry) async {
        revertingId = entry.id
        defer { revertingId = nil }
        do {
            let _: OKResponse = try await api.post("/api/audit-log/\(entry.id)/revert")
            Haptics.success()
            statusMessage = "Reverted \(entry.action)."
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to revert this entry."
            Haptics.error()
        }
    }
}
