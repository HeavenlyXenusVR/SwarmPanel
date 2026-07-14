import SwiftUI
import UIKit

private enum TrackSort: String, CaseIterable {
    case plays = "Plays"
    case likes = "Likes"
}

struct LeaderboardView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var notificationsViewModel: NotificationsViewModel
    @EnvironmentObject private var toastCenter: ToastCenter
    @StateObject private var viewModel = LeaderboardViewModel()
    @State private var trackSort: TrackSort = .plays

    private func sortedTracks(_ tracks: [LeaderboardTrack]) -> [LeaderboardTrack] {
        switch trackSort {
        case .plays: return tracks.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        case .likes: return tracks.sorted { ($0.likeCount ?? 0) > ($1.likeCount ?? 0) }
        }
    }

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
                        ErrorBanner(message: error).padding(.horizontal)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SectionLabel(title: "Top Tracks")
                            Spacer()
                            Picker("Sort", selection: $trackSort) {
                                ForEach(TrackSort.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 160)
                        }
                        let tracks = sortedTracks(viewModel.data?.topTracks ?? [])
                        if viewModel.isLoading && viewModel.data == nil {
                            SkeletonList(rowCount: 3)
                        } else if tracks.isEmpty {
                            PanelCard { EmptyStateView(icon: "music.note.list", title: "No track history yet.") }
                        } else {
                            PanelCard(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                        if index > 0 { Divider().overlay(SwarmTheme.line) }
                                        RankRow(
                                            rank: index + 1,
                                            title: track.title?.isEmpty == false ? track.title! : "Untitled",
                                            subtitle: "\(track.playCount ?? 0) plays · \(track.likeCount ?? 0) likes",
                                            videoUrl: track.videoUrl
                                        )
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            guard let videoUrl = track.videoUrl, let url = URL(string: videoUrl) else { return }
                                            UIApplication.shared.open(url)
                                        }
                                        .contextMenu {
                                            if let videoUrl = track.videoUrl {
                                                Button {
                                                    UIPasteboard.general.string = videoUrl
                                                    Haptics.success()
                                                    toastCenter.success("Link copied")
                                                } label: {
                                                    Label("Copy Link", systemImage: "doc.on.doc")
                                                }
                                                Button {
                                                    guard let url = URL(string: videoUrl) else { return }
                                                    UIApplication.shared.open(url)
                                                } label: {
                                                    Label("Open in Safari", systemImage: "safari")
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(title: "Top Listeners")
                        let listeners = viewModel.data?.topListeners ?? []
                        if viewModel.isLoading && viewModel.data == nil {
                            SkeletonList(rowCount: 3)
                        } else if listeners.isEmpty {
                            PanelCard { EmptyStateView(icon: "person.3", title: "No listener history yet.") }
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
            .refreshable {
                Haptics.light()
                await viewModel.loadLeaderboard()
            }
            .notificationsBell(notificationsViewModel)
        }
    }
}

private struct RankRow: View {
    let rank: Int
    let title: String
    let subtitle: String
    var videoUrl: String? = nil

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
            if videoUrl?.isEmpty == false {
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundStyle(SwarmTheme.textMuted)
            }
        }
        .padding(14)
    }
}

#Preview {
    LeaderboardView()
        .environmentObject(AppState())
        .environmentObject(NotificationsViewModel())
        .environmentObject(ToastCenter())
}
