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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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
                        positionObservedAt: session.positionObservedAt
                    )
                    .padding(.horizontal)

                    PanelCard {
                        StatRow(icon: "music.note.list", tint: .purple, label: "Queue", value: "\(session.queueCount ?? 0)")
                        StatRow(icon: "arrow.triangle.2.circlepath", tint: .indigo, label: "Backup Queue", value: "\(session.backupQueueCount ?? 0)")
                        if let volume = session.volume {
                            StatRow(icon: "speaker.wave.2.fill", tint: .orange, label: "Volume", value: "\(volume)%")
                        }
                        Divider().overlay(SwarmTheme.line)
                        HStack {
                            IconChip(systemName: "repeat", tint: .teal)
                            Text("Loop").foregroundStyle(SwarmTheme.textMuted)
                            Spacer()
                            Menu {
                                ForEach(loopModes, id: \.self) { mode in
                                    Button(mode.capitalized) {
                                        Task { await setLoopMode(mode) }
                                    }
                                }
                            } label: {
                                Label((session.loopMode ?? "queue").capitalized, systemImage: "chevron.up.chevron.down")
                                    .font(.subheadline)
                            }
                            .disabled(viewModel.isSending)
                        }
                        HStack {
                            IconChip(systemName: "slider.horizontal.3", tint: .pink)
                            Text("Filter").foregroundStyle(SwarmTheme.textMuted)
                            Spacer()
                            Menu {
                                ForEach(filterModes, id: \.self) { mode in
                                    Button(mode.capitalized) {
                                        Task { await setFilterMode(mode) }
                                    }
                                }
                            } label: {
                                Label((session.filterMode ?? "none").capitalized, systemImage: "chevron.up.chevron.down")
                                    .font(.subheadline)
                            }
                            .disabled(viewModel.isSending)
                        }
                        if let pending = session.pendingDirectOrders, pending > 0 {
                            Divider().overlay(SwarmTheme.line)
                            StatRow(icon: "clock.badge.exclamationmark", tint: SwarmTheme.warn, label: "Pending Orders", value: "\(pending)")
                            if let command = session.latestDirectOrder?.command {
                                Text("Waiting on the bot to pick up: \(command)")
                                    .font(.caption2)
                                    .foregroundStyle(SwarmTheme.textMuted)
                            }
                        }
                    }
                    .padding(.horizontal)

                    if let items = session.queuePreview, !items.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel(title: "Up Next", count: items.count)
                            PanelCard(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                                        if index > 0 { Divider().overlay(SwarmTheme.line) }
                                        Text(item.title?.isEmpty == false ? item.title! : item.videoUrl)
                                            .font(.caption)
                                            .foregroundStyle(SwarmTheme.textPrimary)
                                            .lineLimit(1)
                                            .padding(12)
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
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                } else if viewModel.isLoading {
                    SkeletonCard(lines: 4).padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(SwarmTheme.background)
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

private struct StatRow: View {
    let icon: String
    let tint: Color
    let label: String
    let value: String

    var body: some View {
        HStack {
            IconChip(systemName: icon, tint: tint)
            Text(label).foregroundStyle(SwarmTheme.textMuted)
            Spacer()
            Text(value).foregroundStyle(SwarmTheme.textPrimary)
        }
    }
}
