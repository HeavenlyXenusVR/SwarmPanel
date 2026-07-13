import Foundation

/// GET /api/metrics/history?metric=&hours= -> {"ok": true, ..., "points": [...]}
struct MetricHistoryResponse: Decodable {
    let points: [MetricPoint]?
}

struct MetricPoint: Decodable {
    let metricValue: Double
    let capturedAt: String?
}

/// GET /api/metrics/anomalies?metric=&hours= -> {"ok": true, ..., "anomalies": [...]}
struct MetricAnomaliesResponse: Decodable {
    let anomalies: [MetricAnomaly]?
}

struct MetricAnomaly: Decodable {
    let metricValue: Double
    let capturedAt: String?
    let zScore: Double?
}
