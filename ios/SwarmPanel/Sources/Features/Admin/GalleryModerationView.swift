import SwiftUI

struct GalleryModerationView: View {
    @StateObject private var viewModel = GalleryModerationViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(SwarmTheme.danger).padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: "Reports", count: viewModel.reports.count)
                    if viewModel.reports.isEmpty {
                        PanelCard { EmptyStateView(icon: "flag", title: "No reports.") }
                    } else {
                        PanelCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(viewModel.reports.enumerated()), id: \.element.id) { index, report in
                                    if index > 0 { Divider().overlay(SwarmTheme.line) }
                                    ReportRow(report: report, viewModel: viewModel)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: "Comments", count: viewModel.comments.count)
                    if viewModel.comments.isEmpty {
                        PanelCard { EmptyStateView(icon: "bubble.left", title: "No comments.") }
                    } else {
                        PanelCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(viewModel.comments.enumerated()), id: \.element.id) { index, comment in
                                    if index > 0 { Divider().overlay(SwarmTheme.line) }
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(comment.body ?? "").font(.caption).foregroundStyle(SwarmTheme.textPrimary).lineLimit(2)
                                            Text("\(comment.username ?? "unknown") on \(comment.mediaTitle ?? "media")")
                                                .font(.caption2)
                                                .foregroundStyle(SwarmTheme.textMuted)
                                        }
                                        Spacer()
                                        Button(role: .destructive) {
                                            Task { await viewModel.deleteComment(comment) }
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .tint(SwarmTheme.danger)
                                    }
                                    .padding(14)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(SwarmTheme.background)
        .navigationTitle("Gallery Moderation")
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }
}

private struct ReportRow: View {
    let report: GalleryReport
    @ObservedObject var viewModel: GalleryModerationViewModel

    var body: some View {
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
        .padding(14)
    }
}

#Preview {
    NavigationStack { GalleryModerationView() }
}
