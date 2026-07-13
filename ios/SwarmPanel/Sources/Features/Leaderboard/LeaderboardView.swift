import SwiftUI

struct LeaderboardView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = LeaderboardViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PanelCard {
                        HStack {
                            Text("Bot").foregroundStyle(SwarmTheme.textMuted)
                            Spacer()
                            Picker("Bot", selection: $viewModel.selectedBotKey) {
                                ForEach(viewModel.bots) { bot in
                                    Text(bot.label).tag(bot.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(SwarmTheme.accent)
                        }
                        Divider().overlay(SwarmTheme.line)
                        HStack {
                            Text("Guild").foregroundStyle(SwarmTheme.textMuted)
                            TextField("Guild ID", text: $viewModel.guildId)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .padding(.horizontal)

                    if let error = viewModel.errorMessage {
                        Text(error).foregroundStyle(SwarmTheme.danger).padding(.horizontal)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(title: "Top Tracks")
                        let tracks = viewModel.data?.topTracks ?? []
                        if tracks.isEmpty {
                            PanelCard { Text("No track history yet.").foregroundStyle(SwarmTheme.textMuted) }
                        } else {
                            PanelCard(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                        if index > 0 { Divider().overlay(SwarmTheme.line) }
                                        RankRow(
                                            rank: index + 1,
                                            title: track.title?.isEmpty == false ? track.title! : "Untitled",
                                            subtitle: "\(track.playCount ?? 0) plays · \(track.likeCount ?? 0) likes"
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(title: "Top Listeners")
                        let listeners = viewModel.data?.topListeners ?? []
                        if listeners.isEmpty {
                            PanelCard { Text("No listener history yet.").foregroundStyle(SwarmTheme.textMuted) }
                        } else {
                            PanelCard(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(Array(listeners.enumerated()), id: \.element.id) { index, listener in
                                        if index > 0 { Divider().overlay(SwarmTheme.line) }
                                        RankRow(
                                            rank: index + 1,
                                            title: "Listener \(listener.userId.map(String.init) ?? "?")",
                                            subtitle: "\(listener.trackCount ?? 0) tracks · \(listener.playCount ?? 0) plays"
                                        )
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
            .overlay {
                if viewModel.isLoading && viewModel.data == nil {
                    ProgressView("Loading leaderboard...")
                }
            }
            .navigationTitle("Leaderboard")
            .task {
                if viewModel.guildId.isEmpty { viewModel.guildId = appState.guildId ?? "" }
                await viewModel.loadBots()
                await viewModel.loadLeaderboard()
            }
            .onChange(of: viewModel.selectedBotKey) { _ in
                Task { await viewModel.loadLeaderboard() }
            }
            .onChange(of: viewModel.guildId) { _ in
                Task { await viewModel.loadLeaderboard() }
            }
            .refreshable { await viewModel.loadLeaderboard() }
        }
    }
}

private struct RankRow: View {
    let rank: Int
    let title: String
    let subtitle: String

    private var badgeColor: Color {
        switch rank {
        case 1: return Color(hex: "FFD700") ?? SwarmTheme.warn
        case 2: return Color(hex: "C0C0C0") ?? SwarmTheme.textMuted
        case 3: return Color(hex: "CD7F32") ?? SwarmTheme.warn
        default: return SwarmTheme.panel2
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.caption.bold())
                .frame(width: 26, height: 26)
                .background(badgeColor.opacity(rank <= 3 ? 0.35 : 1), in: Circle())
                .foregroundStyle(rank <= 3 ? SwarmTheme.textPrimary : SwarmTheme.textMuted)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(SwarmTheme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(SwarmTheme.textMuted)
            }
            Spacer()
        }
        .padding(14)
    }
}

#Preview {
    LeaderboardView()
        .environmentObject(AppState())
}
