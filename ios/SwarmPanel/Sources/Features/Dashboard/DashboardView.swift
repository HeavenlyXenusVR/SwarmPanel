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
                } else {
                    List {
                        if let error = viewModel.errorMessage {
                            Section { Text(error).foregroundStyle(.red) }
                        }

                        Section("Fleet") {
                            HStack {
                                metric("Bots", "\(allBots.count)")
                                Spacer()
                                metric("Live", "\(allSessions.filter { $0.isPlaying == true }.count)")
                                Spacer()
                                metric("Queued", "\(allSessions.reduce(0) { $0 + ($1.queueCount ?? 0) })")
                            }
                            .padding(.vertical, 4)
                        }

                        if let ownSession, let ownBotKey {
                            Section("Your Guild") {
                                QuickControlCard(session: ownSession, botKey: ownBotKey)
                            }
                        }

                        Section("Live Sessions") {
                            if allSessions.isEmpty {
                                Text("No active sessions right now.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(allSessions) { session in
                                    SessionRow(session: session)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await viewModel.refresh() }
                }
            }
            .navigationTitle("Dashboard")
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SessionRow: View {
    let session: DashboardSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title?.isEmpty == false ? session.title! : "No title")
                .font(.headline)
            Text(session.channelName ?? session.guildName ?? "Guild \(session.guildId ?? "?")")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Label("\(session.queueCount ?? 0)", systemImage: "music.note.list")
                Label("\(session.backupQueueCount ?? 0)", systemImage: "arrow.triangle.2.circlepath")
                if session.isPlaying == true {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(session.title?.isEmpty == false ? session.title! : "Nothing playing right now.")
                .font(.subheadline.bold())
            HStack(spacing: 20) {
                Button {
                    Task { await send(isCurrentlyPlaying ? "PAUSE" : "RESUME") }
                } label: {
                    Image(systemName: isCurrentlyPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 32, height: 32)
                }
                Button {
                    Task { await send("SKIP") }
                } label: {
                    Image(systemName: "forward.fill")
                        .frame(width: 32, height: 32)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
        }
        .padding(.vertical, 4)
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
            // Best-effort — Phase 4's Controls screen surfaces errors properly;
            // a failed quick-action here just leaves the button re-enabled.
        }
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppState())
}
