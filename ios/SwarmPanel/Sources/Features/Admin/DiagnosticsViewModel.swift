import Foundation

@MainActor
final class DiagnosticsViewModel: ObservableObject {
    @Published var diagnosticsText = ""
    @Published var metricsText = ""
    @Published var stabilityText = ""
    @Published var events: [FeedEvent] = []
    @Published var isLoading = true
    @Published var errorMessage: String?

    private let api = APIClient.shared

    func load() async {
        isLoading = true
        defer { isLoading = false }
        async let diagnostics = fetchRaw("/api/system-diagnostics")
        async let metrics = fetchRaw("/api/metrics")
        async let stability = fetchRaw("/api/stability")
        async let loadedEvents = fetchEvents()
        let (d, m, s, e) = await (diagnostics, metrics, stability, loadedEvents)
        diagnosticsText = d
        metricsText = m
        stabilityText = s
        events = e
    }

    private func fetchEvents() async -> [FeedEvent] {
        do {
            let response: EventsResponse = try await api.get("/api/events", query: ["limit": "80"])
            return response.events ?? []
        } catch {
            return []
        }
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
