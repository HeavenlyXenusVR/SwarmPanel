import SwiftUI

struct LumisoundAdminView: View {
    @StateObject private var viewModel = LumisoundAdminViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(SwarmTheme.danger).padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: "Bug Reports", count: viewModel.bugReports.count)
                    if viewModel.bugReports.isEmpty {
                        PanelCard { EmptyStateView(icon: "ladybug", title: "No bug reports.") }
                    } else {
                        PanelCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(viewModel.bugReports.enumerated()), id: \.element.id) { index, report in
                                    if index > 0 { Divider().overlay(SwarmTheme.line) }
                                    BugReportRow(report: report, viewModel: viewModel)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: "Uploads", count: viewModel.uploads.count)
                    if viewModel.uploads.isEmpty {
                        PanelCard { EmptyStateView(icon: "waveform", title: "No uploads.") }
                    } else {
                        PanelCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(viewModel.uploads.enumerated()), id: \.element.id) { index, upload in
                                    if index > 0 { Divider().overlay(SwarmTheme.line) }
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(upload.title?.isEmpty == false ? upload.title! : (upload.filename ?? "Untitled"))
                                                .font(.subheadline.bold())
                                                .foregroundStyle(SwarmTheme.textPrimary)
                                            Text(upload.username ?? "unknown")
                                                .font(.caption)
                                                .foregroundStyle(SwarmTheme.textMuted)
                                        }
                                        Spacer()
                                        Button(role: .destructive) {
                                            Task { await viewModel.deleteUpload(upload) }
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

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: "Users", count: viewModel.users.count)
                    if viewModel.users.isEmpty {
                        PanelCard { EmptyStateView(icon: "person.3", title: "No users.") }
                    } else {
                        PanelCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(viewModel.users.enumerated()), id: \.element.id) { index, user in
                                    if index > 0 { Divider().overlay(SwarmTheme.line) }
                                    HStack {
                                        Text(user.username ?? "unknown").foregroundStyle(SwarmTheme.textPrimary)
                                        Spacer()
                                        StatusPill(text: user.isActive == true ? "Active" : "Suspended", tone: user.isActive == true ? .live : .danger)
                                        Button(user.isActive == true ? "Suspend" : "Reinstate") {
                                            Task { await viewModel.setUserActive(user, active: !(user.isActive ?? true)) }
                                        }
                                        .buttonStyle(.borderless)
                                        .tint(SwarmTheme.accent)
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
        .navigationTitle("Lumisound")
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }
}

private struct BugReportRow: View {
    let report: LumisoundBugReport
    @ObservedObject var viewModel: LumisoundAdminViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(report.category?.capitalized ?? "Bug")
                    .font(.subheadline.bold())
                    .foregroundStyle(SwarmTheme.textPrimary)
                Spacer()
                StatusPill(text: report.status?.capitalized ?? "Open", tone: report.status == "resolved" ? .off : .soft)
            }
            if let description = report.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(SwarmTheme.textMuted)
                    .lineLimit(2)
            }
            if report.status != "resolved" {
                Button("Mark Resolved") {
                    Task { await viewModel.setBugReportStatus(report, status: "resolved") }
                }
                .buttonStyle(.borderless)
                .tint(SwarmTheme.accent)
                .font(.caption)
            }
        }
        .padding(14)
    }
}

#Preview {
    NavigationStack { LumisoundAdminView() }
}
