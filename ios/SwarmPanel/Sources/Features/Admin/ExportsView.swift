import SwiftUI

struct ExportsView: View {
    @StateObject private var viewModel = ExportsViewModel()
    @State private var shareURL: IdentifiableURL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(SwarmTheme.danger).padding(.horizontal)
                }

                if !viewModel.enabled {
                    PanelCard {
                        Text("Scheduled exports are disabled. Set PANEL_SCHEDULED_EXPORTS_ENABLED=true on the backend to enable nightly CSV snapshots.")
                            .font(.caption)
                            .foregroundStyle(SwarmTheme.textMuted)
                    }
                    .padding(.horizontal)
                }

                if viewModel.snapshots.isEmpty {
                    PanelCard { EmptyStateView(icon: "tray.and.arrow.down", title: "No scheduled exports yet.") }
                        .padding(.horizontal)
                } else {
                    ForEach(viewModel.snapshots) { snapshot in
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel(title: snapshot.date)
                            PanelCard(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(Array((snapshot.files ?? []).enumerated()), id: \.element.id) { index, file in
                                        if index > 0 { Divider().overlay(SwarmTheme.line) }
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(file.name).font(.subheadline).foregroundStyle(SwarmTheme.textPrimary)
                                                Text(file.sizeDescription).font(.caption2).foregroundStyle(SwarmTheme.textMuted)
                                            }
                                            Spacer()
                                            Button {
                                                Task {
                                                    if let url = await viewModel.download(date: snapshot.date, file: file) {
                                                        shareURL = IdentifiableURL(url: url)
                                                    }
                                                }
                                            } label: {
                                                if viewModel.downloadingFileId == file.id {
                                                    ProgressView()
                                                } else {
                                                    Image(systemName: "square.and.arrow.down")
                                                }
                                            }
                                            .tint(SwarmTheme.accent)
                                        }
                                        .padding(14)
                                    }
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
        .navigationTitle("Scheduled Exports")
        .task { await viewModel.load() }
        .refreshable {
            Haptics.light()
            await viewModel.load()
        }
        .sheet(item: $shareURL) { item in
            ActivityShareSheet(activityItems: [item.url])
        }
    }
}

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

#Preview {
    NavigationStack { ExportsView() }
}
