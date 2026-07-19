import SwiftUI

struct DatabasesView: View {
    @StateObject private var viewModel = DatabasesViewModel()
    @State private var shareURL: IdentifiableURL?
    @State private var isExporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error).padding(.horizontal)
                }

                PanelCard {
                    Picker("Schema", selection: $viewModel.selectedSchema) {
                        ForEach(viewModel.schemas) { schema in
                            Text(schema.schema).tag(schema.schema)
                        }
                    }
                    Picker("Table", selection: $viewModel.selectedTable) {
                        ForEach(viewModel.tables, id: \.self) { table in
                            Text(table).tag(table)
                        }
                    }
                    HStack {
                        Button {
                            Task { await viewModel.loadRows() }
                        } label: {
                            if viewModel.isLoadingRows {
                                ProgressView()
                            } else {
                                Label("Load", systemImage: "tablecells")
                            }
                        }
                        .disabled(viewModel.isLoadingRows || viewModel.selectedTable.isEmpty)

                        Spacer()

                        Button {
                            Task {
                                isExporting = true
                                if let url = await viewModel.exportCSV() { shareURL = IdentifiableURL(url: url) }
                                isExporting = false
                            }
                        } label: {
                            if isExporting {
                                ProgressView()
                            } else {
                                Label("Export CSV", systemImage: "square.and.arrow.down")
                            }
                        }
                        .disabled(isExporting || viewModel.selectedTable.isEmpty)
                    }
                    .tint(SwarmTheme.accent)
                }
                .padding(.horizontal)

                if viewModel.rows.isEmpty {
                    PanelCard { EmptyStateView(icon: "cylinder.split.1x2", title: "No rows loaded yet.") }
                        .padding(.horizontal)
                } else {
                    ForEach(Array(viewModel.rows.enumerated()), id: \.offset) { _, row in
                        PanelCard {
                            ForEach(Array(row.keys.sorted()), id: \.self) { key in
                                HStack(alignment: .top) {
                                    Text(key).font(.caption.bold()).foregroundStyle(SwarmTheme.textMuted)
                                    Spacer()
                                    Text(row[key]?.displayString ?? "—")
                                        .font(.caption)
                                        .foregroundStyle(SwarmTheme.textPrimary)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
        .background(SwarmTheme.background)
        .navigationTitle("Database Viewer")
        .task { await viewModel.loadSchemas() }
        .onChange(of: viewModel.selectedSchema) { _ in
            viewModel.selectedTable = viewModel.tables.first ?? ""
            viewModel.rows = []
        }
        .refreshable {
            Haptics.light()
            await viewModel.loadSchemas()
        }
        .refreshOnForeground { await viewModel.loadSchemas() }
        .sheet(item: $shareURL) { item in
            ActivityShareSheet(activityItems: [item.url])
        }
    }
}

#Preview {
    NavigationStack { DatabasesView() }
        .environmentObject(ToastCenter())
}
