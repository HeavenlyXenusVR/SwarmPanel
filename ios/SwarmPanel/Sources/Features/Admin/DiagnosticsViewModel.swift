import Foundation

@MainActor
final class DiagnosticsViewModel: ObservableObject {
    @Published var diagnosticsText = ""
    @Published var metricsText = ""
    @Published var stabilityText = ""
    @Published var isLoading = true
    @Published var errorMessage: String?

    private let api = APIClient.shared

    func load() async {
        isLoading = true
        defer { isLoading = false }
        async let diagnostics = fetchRaw("/api/system-diagnostics")
        async let metrics = fetchRaw("/api/metrics")
        async let stability = fetchRaw("/api/stability")
        let (d, m, s) = await (diagnostics, metrics, stability)
        diagnosticsText = d
        metricsText = m
        stabilityText = s
    }

    private func fetchRaw(_ path: String) async -> String {
        do {
            let value: [String: JSONValue] = try await api.get(path)
            return JSONValue.object(value).prettyPrinted
        } catch {
            if error.isCancellation { return "" }
            return "Unavailable: \((error as? LocalizedError)?.errorDescription ?? "request failed")"
        }
    }
}
