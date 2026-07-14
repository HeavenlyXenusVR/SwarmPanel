import SwiftUI

struct DiagnosticsView: View {
    @StateObject private var viewModel = DiagnosticsViewModel()
    @StateObject private var chartViewModel = MetricsChartViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel(title: "24h Trends")
                    PanelCard {
                        MetricTrendChart(label: "Queued Tracks", points: chartViewModel.queuedPoints, anomalies: chartViewModel.queuedAnomalies)
                        Divider().overlay(SwarmTheme.line)
                        MetricTrendChart(label: "Active Bots", points: chartViewModel.activeBotsPoints, anomalies: chartViewModel.activeBotsAnomalies)
                    }
                }
                .padding(.horizontal)

                if viewModel.isLoading && viewModel.diagnosticsText.isEmpty {
                    VStack(spacing: 14) {
                        SkeletonCard(lines: 3)
                        SkeletonCard(lines: 3)
                        SkeletonCard(lines: 3)
                    }
                    .padding(.horizontal)
                } else {
                    JSONSection(title: "System Diagnostics", text: viewModel.diagnosticsText)
                    JSONSection(title: "Metrics", text: viewModel.metricsText)
                    JSONSection(title: "Stability", text: viewModel.stabilityText)
                }
            }
            .padding(.vertical)
        }
        .background(SwarmTheme.background)
        .navigationTitle("Fleet Health")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                ShareLink(item: combinedReportText) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(viewModel.diagnosticsText.isEmpty)
            }
        }
        .task {
            await viewModel.load()
            await chartViewModel.load()
        }
        .refreshable {
            Haptics.light()
            await viewModel.load()
            await chartViewModel.load()
        }
    }

    private var combinedReportText: String {
        """
        System Diagnostics
        \(viewModel.diagnosticsText)

        Metrics
        \(viewModel.metricsText)

        Stability
        \(viewModel.stabilityText)
        """
    }
}

private struct JSONSection: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: title)
            PanelCard {
                ScrollView(.horizontal) {
                    Text(text.isEmpty ? "—" : text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(SwarmTheme.textPrimary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal)
    }
}

#Preview {
    NavigationStack { DiagnosticsView() }
}
