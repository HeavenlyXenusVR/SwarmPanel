import SwiftUI

/// Bot x guild coverage map — which bot is serving which guild/channel, and
/// where more than one bot is covering the same guild at once. Admin-only,
/// reached from Profile > Admin Tools alongside Fleet Health.
struct FleetTopologyView: View {
    @StateObject private var viewModel = FleetTopologyViewModel()
    @State private var restartTarget: DashboardBot?
    @State private var confirmingRecoverAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error).padding(.horizontal)
                }
                if let status = viewModel.statusMessage {
                    Text(status).font(.caption).foregroundStyle(SwarmTheme.ok).padding(.horizontal)
                }

                if viewModel.isLoading && viewModel.bots.isEmpty {
                    SkeletonList(rowCount: 4).padding(.horizontal)
                } else if viewModel.bots.isEmpty {
                    PanelCard { EmptyStateView(icon: "point.3.filled.connected.trianglepath.dotted", title: "No bots reporting yet.") }
                        .padding(.horizontal)
                } else {
                    if !viewModel.overlaps.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel(title: "Overlapping Coverage", count: viewModel.overlaps.count)
                            PanelCard(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(Array(viewModel.overlaps.enumerated()), id: \.element.id) { index, overlap in
                                        if index > 0 { Divider().overlay(SwarmTheme.line) }
                                        HStack(spacing: 12) {
                                            IconChip(systemName: "exclamationmark.triangle.fill", tint: SwarmTheme.warn)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(overlap.guildLabel).font(.subheadline.bold()).foregroundStyle(SwarmTheme.textPrimary)
                                                Text(overlap.botLabels.joined(separator: " · ")).font(.caption).foregroundStyle(SwarmTheme.textMuted)
                                            }
                                            Spacer()
                                        }
                                        .padding(14)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    } else {
                        Text("No guild is currently covered by more than one bot.")
                            .font(.caption)
                            .foregroundStyle(SwarmTheme.textMuted)
                            .padding(.horizontal)
                    }

                    if !viewModel.recoverableSessions.isEmpty {
                        PanelCard {
                            HStack(spacing: 12) {
                                IconChip(systemName: "arrow.triangle.2.circlepath", tint: SwarmTheme.warn)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(viewModel.recoverableSessions.count) session(s) pending recovery")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(SwarmTheme.textPrimary)
                                    Text("Send RECOVER to every one at once.")
                                        .font(.caption)
                                        .foregroundStyle(SwarmTheme.textMuted)
                                }
                                Spacer()
                                Button {
                                    confirmingRecoverAll = true
                                } label: {
                                    if viewModel.isRecoveringAll {
                                        ProgressView()
                                    } else {
                                        Text("Recover All")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(viewModel.isRecoveringAll)
                            }
                        }
                        .padding(.horizontal)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(title: "Bots", count: viewModel.bots.count)
                        PanelCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(viewModel.bots.enumerated()), id: \.element.id) { index, bot in
                                    if index > 0 { Divider().overlay(SwarmTheme.line) }
                                    BotTopologyRow(
                                        bot: bot,
                                        isRestarting: viewModel.restartingBotKey == bot.key,
                                        onRestart: { restartTarget = bot }
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(SwarmTheme.background)
        .navigationTitle("Fleet Topology")
        .task { await viewModel.load() }
        .refreshable {
            Haptics.light()
            await viewModel.load()
        }
        .refreshOnForeground { await viewModel.load() }
        .confirmationDialog(
            "Restart \(restartTarget?.displayName?.isEmpty == false ? restartTarget!.displayName! : (restartTarget?.key ?? "this bot"))?",
            isPresented: Binding(get: { restartTarget != nil }, set: { if !$0 { restartTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restart", role: .destructive) {
                if let target = restartTarget { Task { await viewModel.restart(target) } }
                restartTarget = nil
            }
            Button("Cancel", role: .cancel) { restartTarget = nil }
        } message: {
            Text("This restarts the bot process fleet-wide, not just one guild. Every guild it's currently serving will briefly disconnect.")
        }
        .confirmationDialog(
            "Recover \(viewModel.recoverableSessions.count) session(s)?",
            isPresented: $confirmingRecoverAll,
            titleVisibility: .visible
        ) {
            Button("Recover All") { Task { await viewModel.recoverAllStale() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sends RECOVER to every bot/guild session currently pending recovery.")
        }
    }
}

private struct BotTopologyRow: View {
    let bot: DashboardBot
    let isRestarting: Bool
    let onRestart: () -> Void

    private var statusTone: StatusTone {
        switch bot.heartbeatStatus {
        case "online": return .live
        case "stale", "error": return .danger
        default: return .off
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                IconChip(systemName: "server.rack", tint: .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.displayName?.isEmpty == false ? bot.displayName! : bot.key)
                        .font(.subheadline.bold())
                        .foregroundStyle(SwarmTheme.textPrimary)
                    let count = bot.sessions?.count ?? 0
                    Text("\(count) guild\(count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(SwarmTheme.textMuted)
                }
                Spacer()
                StatusPill(text: (bot.heartbeatStatus ?? "unknown").capitalized, tone: statusTone)
                Button {
                    onRestart()
                } label: {
                    if isRestarting {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise.circle")
                    }
                }
                .tint(SwarmTheme.danger)
                .disabled(isRestarting)
            }
            if let sessions = bot.sessions, !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sessions, id: \.id) { session in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(session.isPlaying == true ? SwarmTheme.ok : SwarmTheme.textMuted)
                                .frame(width: 6, height: 6)
                            Text(session.channelName ?? session.guildName ?? "Guild \(session.guildId ?? "?")")
                                .font(.caption)
                                .foregroundStyle(SwarmTheme.textMuted)
                        }
                    }
                }
                .padding(.leading, 40)
            }
        }
        .padding(14)
    }
}

#Preview {
    NavigationStack { FleetTopologyView() }
        .environmentObject(ToastCenter())
}
