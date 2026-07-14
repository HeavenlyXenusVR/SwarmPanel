import SwiftUI

struct LumisoundAdminView: View {
    @StateObject private var viewModel = LumisoundAdminViewModel()

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Section { Text(error).foregroundStyle(SwarmTheme.danger) }
                    .listRowBackground(SwarmTheme.panel)
            }

            Section {
                if viewModel.bugReports.isEmpty {
                    EmptyStateView(icon: "ladybug", title: "No bug reports.")
                } else {
                    ForEach(viewModel.bugReports) { report in
                        BugReportRow(report: report, viewModel: viewModel)
                    }
                }
            } header: {
                SectionLabel(title: "Bug Reports", count: viewModel.bugReports.count)
            }
            .listRowBackground(SwarmTheme.panel)

            Section {
                if viewModel.uploads.isEmpty {
                    EmptyStateView(icon: "waveform", title: "No uploads.")
                } else {
                    ForEach(viewModel.uploads) { upload in
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
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await viewModel.deleteUpload(upload) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                SectionLabel(title: "Uploads", count: viewModel.uploads.count)
            }
            .listRowBackground(SwarmTheme.panel)

            Section {
                if viewModel.users.isEmpty {
                    EmptyStateView(icon: "person.3", title: "No users.")
                } else {
                    ForEach(viewModel.users) { user in
                        HStack {
                            Text(user.username ?? "unknown").foregroundStyle(SwarmTheme.textPrimary)
                            Spacer()
                            StatusPill(text: user.isActive == true ? "Active" : "Suspended", tone: user.isActive == true ? .live : .danger)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                Task { await viewModel.setUserActive(user, active: !(user.isActive ?? true)) }
                            } label: {
                                Label(user.isActive == true ? "Suspend" : "Reinstate", systemImage: user.isActive == true ? "pause.circle" : "checkmark.circle")
                            }
                            .tint(user.isActive == true ? SwarmTheme.danger : SwarmTheme.accent)
                        }
                    }
                }
            } header: {
                SectionLabel(title: "Users", count: viewModel.users.count)
            }
            .listRowBackground(SwarmTheme.panel)
        }
        .scrollContentBackground(.hidden)
        .background(SwarmTheme.background)
        .navigationTitle("Lumisound")
        .task { await viewModel.load() }
        .refreshable {
            Haptics.light()
            await viewModel.load()
        }
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
