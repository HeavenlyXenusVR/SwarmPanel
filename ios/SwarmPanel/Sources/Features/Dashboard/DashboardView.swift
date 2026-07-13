import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = DashboardViewModel()

    private var allBots: [DashboardBot] { viewModel.response?.bots ?? [] }
    private var allSessions: [DashboardSession] {
        allBots.flatMap { $0.sessions ?? [] }
    }
    private var ownBotKey: String? {
        guard let guildId = appState.guildId else { return nil }
        return allBots.first { bot in (bot.sessions ?? []).contains { $0.guildId == guildId } }?.key
    }
    private var ownSession: DashboardSession? {
        guard let guildId = appState.guildId else { return nil }
        return allSessions.first { $0.guildId == guildId }
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.response == nil {
                    ProgressView("Loading fleet status...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(SwarmTheme.background)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if let error = viewModel.errorMessage {
                                Text(error)
                                    .foregroundStyle(SwarmTheme.danger)
                                    .padding(.horizontal)
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                SectionLabel(title: "Fleet")
                                PanelCard {
                                    HStack(spacing: 0) {
                                        MetricTile(icon: "server.rack", label: "Bots", value: "\(allBots.count)")
                                        MetricTile(icon: "dot.radiowaves.left.and.right", label: "Live", value: "\(allSessions.filter { $0.isPlaying == true }.count)")
                                        MetricTile(icon: "music.note.list", label: "Queued", value: "\(allSessions.reduce(0) { $0 + ($1.queueCount ?? 0) })")
                                    }
                                }
                            }
                            .padding(.horizontal)

                            if let ownSession, let ownBotKey {
                                VStack(alignment: .leading, spacing: 10) {
                                    SectionLabel(title: "Your Guild")
                                    QuickControlCard(session: ownSession, botKey: ownBotKey)
                                }
                                .padding(.horizontal)
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                SectionLabel(title: "Live Sessions", count: allSessions.count)
                                if allSessions.isEmpty {
                                    PanelCard {
                                        Text("No active sessions right now.")
                                            .foregroundStyle(SwarmTheme.textMuted)
                                    }
                                } else {
                                    PanelCard(padding: 0) {
                                        VStack(spacing: 0) {
                                            ForEach(Array(allSessions.enumerated()), id: \.element.id) { index, session in
                                                if index > 0 {
                                                    Divider().overlay(SwarmTheme.line)
                                                }
                                                SessionRow(session: session)
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
                    .refreshable { await viewModel.refresh() }
                }
            }
            .navigationTitle("Dashboard")
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }
}

private struct SessionRow: View {
    let session: DashboardSession

    private var tone: StatusTone {
        if session.isPlaying == true && session.isPaused != true { return .live }
        if session.isPlaying == true && session.isPaused == true { return .soft }
        return .off
    }

    private var statusText: String {
        if session.isPlaying == true && session.isPaused != true { return "Playing" }
        if session.isPaused == true { return "Paused" }
        return session.sessionStateLabel ?? "Idle"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "music.note")
                .font(.subheadline)
                .foregroundStyle(SwarmTheme.accent)
                .frame(width: 28, height: 28)
                .background(SwarmTheme.accent.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(session.title?.isEmpty == false ? session.title! : "No title")
                    .font(.subheadline.bold())
                    .foregroundStyle(SwarmTheme.textPrimary)
                Text(session.channelName ?? session.guildName ?? "Guild \(session.guildId ?? "?")")
                    .font(.caption)
                    .foregroundStyle(SwarmTheme.textMuted)
                HStack(spacing: 12) {
                    Label("\(session.queueCount ?? 0)", systemImage: "music.note.list")
                    Label("\(session.backupQueueCount ?? 0)", systemImage: "arrow.triangle.2.circlepath")
                }
                .font(.caption2)
                .foregroundStyle(SwarmTheme.textMuted)
            }

            Spacer()
            StatusPill(text: statusText, tone: tone)
        }
        .padding(14)
    }
}

private struct QuickControlCard: View {
    let session: DashboardSession
    let botKey: String
    @State private var isBusy = false

    private var isCurrentlyPlaying: Bool {
        session.isPlaying == true && session.isPaused != true
    }

    var body: some View {
        PanelCard {
            Text(session.title?.isEmpty == false ? session.title! : "Nothing playing right now.")
                .font(.subheadline.bold())
                .foregroundStyle(SwarmTheme.textPrimary)
            HStack(spacing: 16) {
                Button {
                    Task { await send(isCurrentlyPlaying ? "PAUSE" : "RESUME") }
                } label: {
                    Image(systemName: isCurrentlyPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 44, height: 44)
                        .background(SwarmTheme.accent.opacity(0.15), in: Circle())
                }
                Button {
                    Task { await send("SKIP") }
                } label: {
                    Image(systemName: "forward.fill")
                        .frame(width: 44, height: 44)
                        .background(SwarmTheme.panel2, in: Circle())
                }
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
    }

    private func send(_ action: String) async {
        guard let guildId = session.guildId else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let _: OKResponse = try await APIClient.shared.post(
                "/api/bots/control",
                body: BotControlRequest(botKey: botKey, guildId: guildId, action: action, payload: [:])
            )
        } catch {
            // Best-effort — the Controls screen surfaces errors properly;
            // a failed quick-action here just leaves the button re-enabled.
        }
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppState())
}
