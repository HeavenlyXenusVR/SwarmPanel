import Foundation

@MainActor
final class DiagnosticsViewModel: ObservableObject {
    @Published var metricsText = ""
    @Published var stabilityText = ""
    @Published var events: [FeedEvent] = []
    @Published var isLoading = true
    @Published var errorMessage: String?

    private let api = APIClient.shared

    func load() async {
        isLoading = true
        defer { isLoading = false }
        // BUGFIX: this used to also fetch "/api/system-diagnostics", which
        // has never existed on the backend (confirmed live: 404) -- the
        // "System Diagnostics" panel it fed always read "Unavailable:
        // request failed" for every user, every time. The web /diagnostics
        // page it's meant to mirror only has Stability + Metrics + Events,
        // so there's nothing real to point that fetch at; removed rather
        // than left calling a route that will never exist.
        async let metrics = fetchRaw("/api/metrics")
        async let stability = fetchRaw("/api/stability")
        async let loadedEvents = fetchEvents()
        let (m, s, e) = await (metrics, stability, loadedEvents)
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
