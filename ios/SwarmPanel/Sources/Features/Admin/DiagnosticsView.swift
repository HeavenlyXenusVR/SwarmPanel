import SwiftUI

struct DiagnosticsView: View {
    @StateObject private var viewModel = DiagnosticsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if viewModel.isLoading && viewModel.diagnosticsText.isEmpty {
                    ProgressView("Loading diagnostics...")
                        .frame(maxWidth: .infinity)
                        .padding()
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
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
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
