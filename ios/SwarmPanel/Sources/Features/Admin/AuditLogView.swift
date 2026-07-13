import SwiftUI

struct AuditLogView: View {
    @StateObject private var viewModel = AuditLogViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(SwarmTheme.danger).padding(.horizontal)
                }
                if viewModel.entries.isEmpty && !viewModel.isLoading {
                    PanelCard { EmptyStateView(icon: "list.bullet.clipboard", title: "No audit log entries yet.") }
                        .padding(.horizontal)
                } else {
                    PanelCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(viewModel.entries.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { Divider().overlay(SwarmTheme.line) }
                                AuditLogRow(entry: entry)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(SwarmTheme.background)
        .navigationTitle("Audit Log")
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }
}

private struct AuditLogRow: View {
    let entry: AuditLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.action)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(SwarmTheme.panel2, in: Capsule())
                    .foregroundStyle(SwarmTheme.textMuted)
                Spacer()
                Text(entry.actorUsername ?? "unknown")
                    .font(.caption)
                    .foregroundStyle(SwarmTheme.textMuted)
            }
            if let targetType = entry.targetType {
                Text("\(targetType): \(entry.targetId ?? "-")")
                    .font(.caption2)
                    .foregroundStyle(SwarmTheme.textMuted)
            }
            if let details = entry.details, !details.isEmpty {
                Text(details)
                    .font(.caption2)
                    .foregroundStyle(SwarmTheme.textMuted)
                    .lineLimit(3)
            }
        }
        .padding(14)
    }
}

#Preview {
    NavigationStack { AuditLogView() }
}
