import Charts
import SwiftUI

/// Native port of the web Intel page's trend charts (TrendChart in
/// components/swarm.jsx) using Swift Charts. Plots by array index rather
/// than parsed Date: captured_at is serialized server-side via Python's
/// naive-datetime isoformat() (no trailing Z/offset), which doesn't match
/// what ISO8601DateFormatter expects — matching anomaly points by their
/// captured_at string instead of parsing dates avoids that risk entirely
/// while still being precise (both endpoints read the same underlying rows).
struct MetricTrendChart: View {
    let label: String
    let points: [MetricPoint]
    let anomalies: [MetricAnomaly]

    private var anomalyTimestamps: Set<String> {
        Set(anomalies.compactMap(\.capturedAt))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(.subheadline.bold()).foregroundStyle(SwarmTheme.textPrimary)
                Spacer()
                if let latest = points.last {
                    Text("\(Int(latest.metricValue))").font(.subheadline.bold()).foregroundStyle(SwarmTheme.accent)
                }
            }
            if points.isEmpty {
                EmptyStateView(icon: "chart.line.uptrend.xyaxis", title: "No \(label.lowercased()) history yet.")
            } else {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                        LineMark(x: .value("Index", index), y: .value("Value", point.metricValue))
                            .foregroundStyle(SwarmTheme.accent)
                        AreaMark(x: .value("Index", index), y: .value("Value", point.metricValue))
                            .foregroundStyle(SwarmTheme.accent.opacity(0.12))
                    }
                    ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                        if let capturedAt = point.capturedAt, anomalyTimestamps.contains(capturedAt) {
                            PointMark(x: .value("Index", index), y: .value("Value", point.metricValue))
                                .foregroundStyle(SwarmTheme.danger)
                                .symbolSize(70)
                        }
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(SwarmTheme.line)
                        AxisValueLabel().foregroundStyle(SwarmTheme.textMuted)
                    }
                }
                .frame(height: 120)

                if !anomalies.isEmpty {
                    Label("\(anomalies.count) anomal\(anomalies.count == 1 ? "y" : "ies") flagged in this window", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(SwarmTheme.danger)
                }
            }
        }
    }
}
