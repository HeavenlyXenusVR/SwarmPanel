import SwiftUI

struct GalleryModerationView: View {
    @StateObject private var viewModel = GalleryModerationViewModel()
    @State private var deleteTarget: GalleryComment?

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Section { ErrorBanner(message: error) }
                    .listRowBackground(SwarmTheme.panel)
            }

            Section {
                if viewModel.reports.isEmpty {
                    EmptyStateView(icon: "flag", title: "No reports.")
                } else {
                    ForEach(viewModel.reports) { report in
                        ReportRow(report: report, viewModel: viewModel)
                    }
                }
            } header: {
                SectionLabel(title: "Reports", count: viewModel.reports.count)
            }
            .listRowBackground(SwarmTheme.panel)

            Section {
                if viewModel.comments.isEmpty {
                    EmptyStateView(icon: "bubble.left", title: "No comments.")
                } else {
                    ForEach(viewModel.comments) { comment in
                        HStack(alignment: .top, spacing: 12) {
                            IconChip(systemName: "bubble.left.fill", tint: .teal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(comment.body ?? "").font(.caption).foregroundStyle(SwarmTheme.textPrimary).lineLimit(2)
                                Text("\(comment.username ?? "unknown") on \(comment.mediaTitle ?? "media")")
                                    .font(.caption2)
                                    .foregroundStyle(SwarmTheme.textMuted)
                            }
                            Spacer()
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteTarget = comment
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                SectionLabel(title: "Comments", count: viewModel.comments.count)
            }
            .listRowBackground(SwarmTheme.panel)
        }
        .scrollContentBackground(.hidden)
        .background(SwarmTheme.background)
        .navigationTitle("Gallery Moderation")
        .task { await viewModel.load() }
        .refreshable {
            Haptics.light()
            await viewModel.load()
        }
        .confirmationDialog(
            "Delete this comment?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget { Task { await viewModel.deleteComment(target) } }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        }
    }
}

private struct ReportRow: View {
    let report: GalleryReport
    @ObservedObject var viewModel: GalleryModerationViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconChip(systemName: "flag.fill", tint: report.status == "open" ? .red : SwarmTheme.textMuted)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(report.reason?.capitalized ?? "Report")
                        .font(.subheadline.bold())
                        .foregroundStyle(SwarmTheme.textPrimary)
                    Spacer()
                    StatusPill(text: report.status?.capitalized ?? "Open", tone: report.status == "open" ? .soft : .off)
                }
                Text("\(report.username ?? "unknown") on \(report.mediaTitle ?? "media")")
                    .font(.caption2)
                    .foregroundStyle(SwarmTheme.textMuted)
                if let details = report.details, !details.isEmpty {
                    Text(details).font(.caption).foregroundStyle(SwarmTheme.textMuted).lineLimit(2)
                }
                if report.status != "dismissed" {
                    HStack {
                        Button("Reviewed") { Task { await viewModel.setReportStatus(report, status: "reviewed") } }
                            .buttonStyle(.borderless)
                            .tint(SwarmTheme.accent)
                        Button("Dismiss") { Task { await viewModel.setReportStatus(report, status: "dismissed") } }
                            .buttonStyle(.borderless)
                            .tint(SwarmTheme.textMuted)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(14)
    }
}

#Preview {
    NavigationStack { GalleryModerationView() }
        .environmentObject(ToastCenter())
}
