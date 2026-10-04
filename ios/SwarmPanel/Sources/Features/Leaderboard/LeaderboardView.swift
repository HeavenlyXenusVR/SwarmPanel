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

    private func loadForCurrentScope() async {
        if viewModel.scope == .swarm && appState.isAdmin {
            await viewModel.loadSwarmLeaderboard()
        } else {
            await viewModel.loadLeaderboard()
        }
    }

    private func sortedTracks(_ tracks: [LeaderboardTrack]) -> [LeaderboardTrack] {
        switch trackSort {
        case .plays: return tracks.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        case .likes: return tracks.sorted { ($0.likeCount ?? 0) > ($1.likeCount ?? 0) }
        }
    }

    /// The top three of whichever list is showing, for the podium.
    private var podiumTracks: [PodiumEntry]? {
        if viewModel.scope == .swarm && appState.isAdmin {
            let tracks = viewModel.swarmData?.tracks ?? []
            return tracks.prefix(3).map {
                PodiumEntry(title: $0.title?.isEmpty == false ? $0.title! : "Untitled", value: "\($0.playCount ?? 0) plays", botKey: $0.botKey)
            }
        }
        let tracks = sortedTracks(viewModel.data?.topTracks ?? [])
        return tracks.prefix(3).map {
            PodiumEntry(
                title: $0.title?.isEmpty == false ? $0.title! : "Untitled",
                value: trackSort == .plays ? "\($0.playCount ?? 0) plays" : "\($0.likeCount ?? 0) likes",
                botKey: viewModel.selectedBotKey.isEmpty ? nil : viewModel.selectedBotKey
            )
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ResScreenHeader(
                        eyebrow: viewModel.scope == .swarm && appState.isAdmin ? "Across the swarm" : "Charts",
                        title: "Insights",
                        subtitle: "What the fleet plays most, and who's listening."
                    )

                    if let podium = podiumTracks, podium.count >= 3 {
                        Podium(entries: podium)
                            .padding(.horizontal)
                    }

                    if appState.isAdmin {
                        Picker("Scope", selection: $viewModel.scope) {
                            ForEach(LeaderboardScope.allCases) { scope in
                                Text(scope.rawValue).tag(scope)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                    }

                    if viewModel.scope == .swarm && appState.isAdmin {
                        PanelCard {
                            HStack {
                                IconChip(systemName: "calendar", tint: .indigo)
                                Text("Window").foregroundStyle(SwarmTheme.textMuted)
                                Spacer()
                                Stepper("\(viewModel.swarmWindowDays) day\(viewModel.swarmWindowDays == 1 ? "" : "s")", value: $viewModel.swarmWindowDays, in: 1...365)
                                    .fixedSize()
                            }
                        }
                        .padding(.horizontal)
                    } else {
                        PanelCard {
                            HStack {
                                IconChip(systemName: "server.rack", tint: .blue)
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
                                IconChip(systemName: "number", tint: .indigo)
                                Text("Guild").foregroundStyle(SwarmTheme.textMuted)
                                TextField("Guild ID", text: $viewModel.guildId)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        .padding(.horizontal)
                    }

                    if let error = viewModel.errorMessage {
                        ErrorBanner(message: error).padding(.horizontal)
                    }

                    if viewModel.scope == .swarm && appState.isAdmin {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                SectionLabel(
                                    title: "Top Tracks — \(viewModel.swarmData?.botsQueried ?? 0) bots",
                                    count: viewModel.swarmData?.tracks?.count
                                )
                            }
                            let tracks = viewModel.swarmData?.tracks ?? []
                            if viewModel.isLoading && viewModel.swarmData == nil {
                                SkeletonList(rowCount: 3)
                            } else if tracks.isEmpty {
                                PanelCard { EmptyStateView(icon: "music.note.list", title: "No track history in this window yet.") }
                            } else {
                                PanelCard(padding: 0) {
                                    VStack(spacing: 0) {
                                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                            if index > 0 { Divider().overlay(SwarmTheme.line) }
                                            RankRow(
                                                rank: index + 1,
                                                title: track.title?.isEmpty == false ? track.title! : "Untitled",
                                                subtitle: "\(track.playCount ?? 0) plays · \(track.botDisplay ?? track.botKey ?? "?")",
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
                    } else {
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
                }
                .padding(.vertical)
                .dockClearance()
            }
            .resonanceScreen()
            .navigationTitle(viewModel.scope == .swarm && appState.isAdmin ? "Swarm Leaderboard" : "Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        LearningView()
                    } label: {
                        Image(systemName: "brain.head.profile")
                    }
                }
            }
            .task {
                if viewModel.guildId.isEmpty { viewModel.guildId = appState.guildId ?? "" }
                await viewModel.loadBots()
                await loadForCurrentScope()
            }
            .onChange(of: viewModel.selectedBotKey) { _ in
                Task { await viewModel.loadLeaderboard() }
            }
            .onChange(of: viewModel.guildId) { _ in
                Task { await viewModel.loadLeaderboard() }
            }
            .onChange(of: viewModel.scope) { _ in
                Task { await loadForCurrentScope() }
            }
            .onChange(of: viewModel.swarmWindowDays) { _ in
                Task { await viewModel.loadSwarmLeaderboard() }
            }
            .refreshable {
                Haptics.light()
                await loadForCurrentScope()
            }
            .refreshOnForeground { await loadForCurrentScope() }
            .notificationsBell(notificationsViewModel)
        }
    }
}

struct PodiumEntry {
    let title: String
    let value: String
    var botKey: String?
}

/// The top three as a podium: first place raised in the middle, each step
/// a glass block with a medal hexagon.
private struct Podium: View {
    let entries: [PodiumEntry]

    @Environment(\.resAccent) private var accent

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            step(entries[1], rank: 2, height: 92)
            step(entries[0], rank: 1, height: 122)
            step(entries[2], rank: 3, height: 74)
        }
        .accessibilityElement(children: .contain)
    }

    private func step(_ entry: PodiumEntry, rank: Int, height: CGFloat) -> some View {
        let medal = medalColor(rank)
        return VStack(spacing: 8) {
            ZStack {
                Hexagon().fill(LinearGradient(colors: [medal, medal.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                Text("\(rank)")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black.opacity(0.75))
            }
            .frame(width: 38, height: 44)
            .shadow(color: medal.opacity(0.55), radius: rank == 1 ? 14 : 8)
            Text(entry.title)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(Res.ink)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 32, alignment: .top)
            Text(entry.value)
                .font(.system(.caption2, design: .rounded).monospacedDigit())
                .foregroundStyle(Res.mist)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [medal.opacity(0.35), medal.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(medal.opacity(0.4), lineWidth: 1))
                .frame(height: height)
                .overlay(alignment: .bottom) {
                    if let botKey = entry.botKey {
                        Hexagon().fill(BotPalette.color(for: botKey)).frame(width: 12, height: 14).padding(.bottom, 10)
                    }
                }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Number \(rank): \(entry.title), \(entry.value)")
    }

    private func medalColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return BotPalette.rgb(0xFFD700)
        case 2: return BotPalette.rgb(0xC9D3DF)
        default: return BotPalette.rgb(0xD9935A)
        }
    }
}

private struct RankRow: View {
    let rank: Int
    let title: String
    let subtitle: String
    var videoUrl: String? = nil

    private var medalColor: Color? {
        switch rank {
        case 1: return BotPalette.rgb(0xFFD700)
        case 2: return BotPalette.rgb(0xC9D3DF)
        case 3: return BotPalette.rgb(0xD9935A)
        default: return nil
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Hexagon()
                    .fill(medalColor.map { AnyShapeStyle($0.gradient) } ?? AnyShapeStyle(Res.well))
                Text("\(rank)")
                    .font(.system(size: 12, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(medalColor == nil ? Res.mist : Color.black.opacity(0.75))
            }
            .frame(width: 28, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(Res.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Res.mist)
            }
            Spacer()
            if videoUrl?.isEmpty == false {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Res.mist)
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
