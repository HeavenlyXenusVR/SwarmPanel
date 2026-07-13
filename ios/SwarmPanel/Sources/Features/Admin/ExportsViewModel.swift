import Foundation

@MainActor
final class ExportsViewModel: ObservableObject {
    @Published var snapshots: [ExportSnapshot] = []
    @Published var enabled = true
    @Published var isLoading = true
    @Published var downloadingFileId: String?
    @Published var errorMessage: String?

    private let api = APIClient.shared

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: ExportsResponse = try await api.get("/api/exports")
            snapshots = response.snapshots ?? []
            enabled = response.enabled ?? false
            errorMessage = nil
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load exports."
        }
    }

    func download(date: String, file: ExportFile) async -> URL? {
        downloadingFileId = file.id
        defer { downloadingFileId = nil }
        do {
            let data = try await api.downloadRaw("/api/exports/\(date)/\(file.name)")
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(date)_\(file.name)")
            try data.write(to: tempURL, options: .atomic)
            return tempURL
        } catch {
            guard !error.isCancellation else { return nil }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to download file."
            return nil
        }
    }
}
