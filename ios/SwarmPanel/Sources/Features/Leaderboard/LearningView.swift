import SwiftUI

/// What the swarm's smart-recommendation engine has learned -- native
/// counterpart to the web panel's /learning page (Round 24), the same
/// GET /api/music-intelligence backend.
struct LearningView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = LearningViewModel()

    private var totals: MusicIntelligenceTotals? { viewModel.data?.totals }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error).padding(.horizontal)
                }

                if viewModel.isLoading && viewModel.data == nil {
                    SkeletonList(rowCount: 3).padding(.horizontal)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(title: "Totals")
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            StatTile(label: "Learned Tracks", value: totals?.learnedTracks ?? 0)
                            StatTile(label: "Smart Recs", value: totals?.recommendations ?? 0)
                            StatTile(label: "Plays", value: totals?.plays ?? 0)
                            StatTile(label: "Finishes", value: totals?.finishes ?? 0)
                            StatTile(label: "Skips", value: totals?.skips ?? 0)
                            StatTile(label: "Likes", value: totals?.likes ?? 0)
                        }
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(title: "By Bot", count: viewModel.data?.bots?.count ?? 0)
                        let bots = viewModel.data?.bots ?? []
                        if bots.isEmpty {
                            PanelCard { EmptyStateView(icon: "brain.head.profile", title: "No music intelligence data yet.") }
                        } else {
                            ForEach(bots) { bot in
                                BotIntelligenceCard(bot: bot)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(SwarmTheme.background)
        .navigationTitle("Learning")
        .task { await viewModel.load(guildId: appState.guildId) }
        .refreshable { await viewModel.load(guildId: appState.guildId) }
    }
}

private struct StatTile: View {
    let label: String
    let value: Int

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(value)").font(.title2.bold()).foregroundStyle(SwarmTheme.textPrimary)
                Text(label).font(.caption).foregroundStyle(SwarmTheme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct BotIntelligenceCard: View {
    let bot: MusicIntelligenceBot

    var body: some View {
        PanelCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    IconChip(systemName: "server.rack", tint: .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bot.botDisplay?.isEmpty == false ? bot.botDisplay! : (bot.botKey ?? "Bot"))
                            .font(.subheadline.bold())
                            .foregroundStyle(SwarmTheme.textPrimary)
                        Text("\(bot.learnedTracks ?? 0) learned tracks, \(bot.recommendations ?? 0) smart recs")
                            .font(.caption2)
                            .foregroundStyle(SwarmTheme.textMuted)
                    }
                    Spacer()
                }
                .padding(14)

                let tracks = bot.topTracks ?? []
                if !tracks.isEmpty {
                    Divider().overlay(SwarmTheme.line)
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        if index > 0 { Divider().overlay(SwarmTheme.line) }
                        HStack {
                            Text(track.title?.isEmpty == false ? track.title! : "Unknown title")
                                .font(.caption)
                                .foregroundStyle(SwarmTheme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text("★ \(track.smartScore ?? 0)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(SwarmTheme.accent)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack { LearningView() }
        .environmentObject(AppState())
}
