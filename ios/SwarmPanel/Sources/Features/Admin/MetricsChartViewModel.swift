import Foundation

@MainActor
final class MetricsChartViewModel: ObservableObject {
    @Published var queuedPoints: [MetricPoint] = []
    @Published var queuedAnomalies: [MetricAnomaly] = []
    @Published var activeBotsPoints: [MetricPoint] = []
    @Published var activeBotsAnomalies: [MetricAnomaly] = []
    @Published var isLoading = true

    private let api = APIClient.shared

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let response: MetricHistoryResponse = try await api.get("/api/metrics/history", query: ["metric": "queued_tracks", "hours": "24"])
            queuedPoints = response.points ?? []
        } catch {
            // Best-effort — a missing trend just renders an empty chart, not an error banner.
        }
        do {
            let response: MetricAnomaliesResponse = try await api.get("/api/metrics/anomalies", query: ["metric": "queued_tracks", "hours": "24"])
            queuedAnomalies = response.anomalies ?? []
        } catch {}
        do {
            let response: MetricHistoryResponse = try await api.get("/api/metrics/history", query: ["metric": "active_bots", "hours": "24"])
            activeBotsPoints = response.points ?? []
        } catch {}
        do {
            let response: MetricAnomaliesResponse = try await api.get("/api/metrics/anomalies", query: ["metric": "active_bots", "hours": "24"])
            activeBotsAnomalies = response.anomalies ?? []
        } catch {}
    }
}
