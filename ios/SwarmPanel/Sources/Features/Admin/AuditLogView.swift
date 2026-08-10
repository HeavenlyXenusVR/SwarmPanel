import SwiftUI

struct AuditLogView: View {
    @StateObject private var viewModel = AuditLogViewModel()
    @State private var revertTarget: AuditLogEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PanelCard {
                    HStack {
                        IconChip(systemName: "line.3.horizontal.decrease", tint: .gray)
                        TextField("Filter by exact action (e.g. truncate_table)", text: $viewModel.actionFilter)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await viewModel.load() } }
                        if !viewModel.actionFilter.isEmpty {
                            Button("Clear") {
                                viewModel.actionFilter = ""
                                Task { await viewModel.load() }
                            }
                            .font(.caption)
                            .tint(SwarmTheme.accent)
                        }
                    }
                }
                .padding(.horizontal)

                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error).padding(.horizontal)
                }
                if let status = viewModel.statusMessage {
                    Text(status).foregroundStyle(SwarmTheme.ok).padding(.horizontal)
                }
                if viewModel.entries.isEmpty && viewModel.isLoading {
                    SkeletonList(rowCount: 5).padding(.horizontal)
                } else if viewModel.entries.isEmpty {
                    PanelCard { EmptyStateView(icon: "list.bullet.clipboard", title: "No audit log entries yet.") }
                        .padding(.horizontal)
                } else {
                    PanelCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(viewModel.entries.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { Divider().overlay(SwarmTheme.line) }
                                AuditLogRow(
                                    entry: entry,
                                    isReverting: viewModel.revertingId == entry.id,
                                    onRevert: { revertTarget = entry }
                                )
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
        .refreshable {
            Haptics.light()
            await viewModel.load()
        }
        .refreshOnForeground { await viewModel.load() }
        .confirmationDialog(
            "Revert \"\(revertTarget?.action ?? "")\"?",
            isPresented: Binding(get: { revertTarget != nil }, set: { if !$0 { revertTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Revert", role: .destructive) {
                if let target = revertTarget { Task { await viewModel.revert(target) } }
                revertTarget = nil
            }
            Button("Cancel", role: .cancel) { revertTarget = nil }
        } message: {
            Text("Restores this entry's target to its state before this action. Not every action can be reverted — the server will say so if this one can't.")
        }
    }
}

private struct AuditLogRow: View {
    let entry: AuditLogEntry
    var isReverting: Bool = false
    var onRevert: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconChip(systemName: "list.bullet.clipboard", tint: .indigo)
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
                if let pairs = entry.diffPairs {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(pairs, id: \.key) { pair in
                            HStack(spacing: 6) {
                                Text(pair.key)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(SwarmTheme.textMuted)
                                Text(pair.before)
                                    .font(.caption2)
                                    .strikethrough()
                                    .foregroundStyle(SwarmTheme.danger)
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(SwarmTheme.textMuted)
                                Text(pair.after)
                                    .font(.caption2.bold())
                                    .foregroundStyle(SwarmTheme.ok)
                            }
                        }
                    }
                } else if let details = entry.details, !details.isEmpty {
                    Text(details)
                        .font(.caption2)
                        .foregroundStyle(SwarmTheme.textMuted)
                        .lineLimit(3)
                }
                if let onRevert {
                    Button {
                        onRevert()
                    } label: {
                        if isReverting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Revert", systemImage: "arrow.uturn.backward")
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .tint(SwarmTheme.warn)
                    .disabled(isReverting)
                }
            }
        }
        .padding(14)
    }
}

#Preview {
    NavigationStack { AuditLogView() }
        .environmentObject(ToastCenter())
}
