import SwiftUI
import UIKit

/// Drill-down from a Dashboard session row into that bot+guild's full
/// control-state — same endpoint the Controls screen uses, just presented
/// read-only here since Controls already covers taking action.
struct BotDetailView: View {
    let botKey: String
    let botDisplayName: String
    let guildId: String
    @StateObject private var viewModel = BotDetailViewModel()
    @EnvironmentObject private var toastCenter: ToastCenter
    @EnvironmentObject private var recentBots: RecentBotsStore
    @EnvironmentObject private var pinnedBots: PinnedBotsStore

    /// The bot's currently-connected voice channel, falling back to its
    /// configured home channel — whichever we have is where "Queue This"
    /// should (re)join to play, since PLAY requires a voice_channel_id.
    private var playbackVoiceChannelId: String? {
        guard let session = viewModel.session else { return nil }
        let candidate = session.channelId ?? session.homeChannelId
        return candidate?.isEmpty == false ? candidate : nil
    }

    private var botColor: Color { BotPalette.color(for: botKey) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero

                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error).padding(.horizontal)
                }
                if let session = viewModel.session {
                    NowPlayingCard(
                        title: session.title ?? "",
                        subtitle: session.sessionStateLabel,
                        thumbnailURL: session.derivedThumbnailURL,
                        isPlaying: session.isPlaying ?? false,
                        isPaused: session.isPaused ?? false,
                        positionSeconds: session.positionSeconds ?? 0,
                        durationSeconds: session.durationSeconds ?? 0,
                        positionObservedAt: session.positionObservedAt,
                        botKey: botKey
                    )
                    .padding(.horizontal)

                    HStack(spacing: 0) {
                        ResReadout(value: "\(session.queueCount ?? 0)", label: "Queue", tint: botColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ResReadout(value: "\(session.backupQueueCount ?? 0)", label: "Backup")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ResReadout(value: session.volume.map { "\($0)%" } ?? "—", label: "Volume")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(18)
                    .resGlass()
                    .padding(.horizontal)

                    if let pending = session.pendingDirectOrders, pending > 0 {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.badge.exclamationmark")
                                .font(.title3)
                                .foregroundStyle(Res.warn)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(pending) order\(pending == 1 ? "" : "s") waiting")
                                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                                    .foregroundStyle(Res.ink)
                                if let command = session.latestDirectOrder?.command {
                                    Text("The bot hasn't picked up \(command) yet.")
                                        .font(.caption)
                                        .foregroundStyle(Res.mist)
                                }
                            }
                            Spacer()
                        }
                        .padding(14)
                        .resGlass(edge: Res.warn)
                        .padding(.horizontal)
                    }

                    modeShelf(title: "Loop", icon: "repeat", options: loopModes, current: session.loopMode ?? "queue") { mode in
                        Task { await setLoopMode(mode) }
                    }
                    modeShelf(title: "Filter", icon: "slider.horizontal.3", options: filterModes, current: session.filterMode ?? "none") { mode in
                        Task { await setFilterMode(mode) }
                    }

                    if let items = session.queuePreview, !items.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ResSectionHeader(eyebrow: "Up next", title: "\(items.count) in the queue")
                            VStack(spacing: 0) {
                                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                                    if index > 0 { Divider().overlay(Res.hairline).padding(.leading, 52) }
                                    upNextRow(index: index, item: item)
                                }
                            }
                            .resGlass()
                            .padding(.horizontal)
                        }
                    }
                } else if viewModel.isLoading {
                    SkeletonCard(lines: 4).padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .resonanceScreen()
        .hidesDock()
        .navigationTitle(botDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    pinnedBots.toggle(botKey: botKey, guildId: guildId, displayName: botDisplayName)
                    Haptics.selection()
                } label: {
                    Image(systemName: pinnedBots.isPinned(botKey: botKey, guildId: guildId) ? "pin.fill" : "pin")
                }
                .accessibilityLabel(pinnedBots.isPinned(botKey: botKey, guildId: guildId) ? "Unpin" : "Pin")
            }
            if let items = viewModel.session?.queuePreview, !items.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: upNextShareText(items)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task {
            await viewModel.load(botKey: botKey, guildId: guildId)
            recentBots.record(botKey: botKey, guildId: guildId, displayName: botDisplayName)
        }
        .refreshable {
            Haptics.light()
            await viewModel.load(botKey: botKey, guildId: guildId)
        }
        .refreshOnForeground { await viewModel.load(botKey: botKey, guildId: guildId) }
    }

    /// The bot's own hexagon, name and the guild this view is scoped to.
    private var hero: some View {
        HStack(spacing: 16) {
            ZStack {
                Hexagon()
                    .fill(LinearGradient(colors: [botColor.opacity(0.85), botColor.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                Hexagon().stroke(botColor, lineWidth: 1.5)
                Text(BotPalette.monogram(for: botKey, name: botDisplayName))
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 64, height: 74)
            .shadow(color: botColor.opacity(0.5), radius: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text("MUSIC BOT")
                    .font(Res.eyebrow)
                    .tracking(1.4)
                    .foregroundStyle(botColor)
                Text(botDisplayName)
                    .font(Res.display(30))
                    .foregroundStyle(Res.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !guildId.isEmpty {
                    Button {
                        UIPasteboard.general.string = guildId
                        Haptics.success()
                        toastCenter.success("Guild ID copied")
                    } label: {
                        Label("Guild \(guildId)", systemImage: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(Res.mist)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private func modeShelf(title: String, icon: String, options: [String], current: String, onPick: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title.uppercased(), systemImage: icon)
                .font(Res.eyebrow)
                .tracking(1.2)
                .foregroundStyle(Res.mist)
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { mode in
                        ResChip(title: mode.capitalized, tint: botColor, isSelected: mode.lowercased() == current.lowercased()) {
                            guard mode.lowercased() != current.lowercased() else { return }
                            Haptics.selection()
                            onPick(mode)
                        }
                        .disabled(viewModel.isSending)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func upNextRow(index: Int, item: QueueItem) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(Res.readout(15))
                .foregroundStyle(index == 0 ? botColor : Res.mist)
                .frame(width: 28)
            Text(item.title?.isEmpty == false ? item.title! : item.videoUrl)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Res.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let url = URL(string: item.videoUrl) else { return }
            UIApplication.shared.open(url)
        }
        .contextMenu {
            if let voiceChannelId = playbackVoiceChannelId {
                Button {
                    Task { await queueThis(item, voiceChannelId: voiceChannelId) }
                } label: {
                    Label("Queue This", systemImage: "text.badge.plus")
                }
            }
            Button {
                UIPasteboard.general.string = item.videoUrl
                Haptics.success()
                toastCenter.success("Link copied")
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
            Button {
                guard let url = URL(string: item.videoUrl) else { return }
                UIApplication.shared.open(url)
            } label: {
                Label("Open in Safari", systemImage: "safari")
            }
        }
    }

    private func upNextShareText(_ items: [QueueItem]) -> String {
        let lines = items.enumerated().map { index, item in
            "\(index + 1). \(item.title?.isEmpty == false ? item.title! : item.videoUrl)"
        }
        return "Up Next on \(botDisplayName):\n" + lines.joined(separator: "\n")
    }

    private func setLoopMode(_ mode: String) async {
        let ok = await viewModel.sendAction(botKey: botKey, guildId: guildId, action: "LOOP", payload: ["loop_mode": mode])
        if ok { Haptics.success(); toastCenter.success("Loop set to \(mode.capitalized)") } else { Haptics.error() }
    }

    private func setFilterMode(_ mode: String) async {
        let ok = await viewModel.sendAction(botKey: botKey, guildId: guildId, action: "FILTER", payload: ["filter_mode": mode])
        if ok { Haptics.success(); toastCenter.success("Filter set to \(mode.capitalized)") } else { Haptics.error() }
    }

    private func queueThis(_ item: QueueItem, voiceChannelId: String) async {
        let ok = await viewModel.sendAction(
            botKey: botKey, guildId: guildId, action: "PLAY",
            payload: ["source_url": item.videoUrl, "voice_channel_id": voiceChannelId]
        )
        if ok {
            Haptics.success()
            toastCenter.success("Queued")
        } else {
            Haptics.error()
        }
    }
}

