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

                if viewModel.isLoading && viewModel.metricsText.isEmpty {
                    VStack(spacing: 14) {
                        SkeletonCard(lines: 3)
                        SkeletonCard(lines: 3)
                        SkeletonCard(lines: 3)
                    }
                    .padding(.horizontal)
                } else {
                    JSONSection(title: "Metrics", icon: "chart.bar.fill", tint: .blue, text: viewModel.metricsText)
                    JSONSection(title: "Stability", icon: "waveform.path.ecg", tint: .orange, text: viewModel.stabilityText)
                    EventsSection(events: viewModel.events)
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
                .disabled(viewModel.metricsText.isEmpty)
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
        .refreshOnForeground {
            await viewModel.load()
            await chartViewModel.load()
        }
    }

    private var combinedReportText: String {
        """
        Metrics
        \(viewModel.metricsText)

        Stability
        \(viewModel.stabilityText)
        """
    }
}

private struct JSONSection: View {
    let title: String
    let icon: String
    let tint: Color
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                IconChip(systemName: icon, tint: tint)
                SectionLabel(title: title)
            }
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

private struct EventsSection: View {
    let events: [FeedEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                IconChip(systemName: "bolt.horizontal.fill", tint: .indigo)
                SectionLabel(title: "Events", count: events.count)
            }
            if events.isEmpty {
                PanelCard { EmptyStateView(icon: "bolt.horizontal", title: "No recent events.") }
            } else {
                PanelCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(events.prefix(40).enumerated()), id: \.element.id) { index, event in
                            if index > 0 { Divider().overlay(SwarmTheme.line) }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(event.title ?? event.type ?? "Event").font(.subheadline.bold()).foregroundStyle(SwarmTheme.textPrimary)
                                    Spacer()
                                    if let source = event.source {
                                        Text(source).font(.caption2).foregroundStyle(SwarmTheme.textMuted)
                                    }
                                }
                                if let description = event.description, !description.isEmpty {
                                    Text(description).font(.caption).foregroundStyle(SwarmTheme.textMuted)
                                }
                                if let timestamp = event.timestamp {
                                    Text(timestamp).font(.caption2).foregroundStyle(SwarmTheme.textMuted)
                                }
                            }
                            .padding(12)
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
    }
}

#Preview {
    NavigationStack { DiagnosticsView() }
}
