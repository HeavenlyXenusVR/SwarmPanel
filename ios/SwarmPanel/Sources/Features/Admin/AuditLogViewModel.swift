import Foundation

@MainActor
final class AuditLogViewModel: ObservableObject {
    @Published var entries: [AuditLogEntry] = []
    @Published var total = 0
    @Published var actionFilter = ""
    @Published var isLoading = true
    @Published var errorMessage: String?

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
}
