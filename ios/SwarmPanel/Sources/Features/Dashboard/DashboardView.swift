import SwiftUI

private let relativeTimeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
}()

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var notificationsViewModel: NotificationsViewModel
    @EnvironmentObject private var toastCenter: ToastCenter
    @StateObject private var viewModel = DashboardViewModel()
    @StateObject private var recentBots = RecentBotsStore()
    @StateObject private var pinnedBots = PinnedBotsStore()

    private var allBots: [DashboardBot] { viewModel.response?.bots ?? [] }
    private var allSessions: [DashboardSession] {
        allBots.flatMap { $0.sessions ?? [] }
    }
    /// Pairs each session with its owning bot and keys identity on
    /// `bot.key`, not just `session.id` (guildId+channelId) — two different
    /// bots can report a session for the same guild/channel (the whole
    /// point of a "swarm" of bots covering overlapping guilds), which would
    /// otherwise give ForEach/NavigationLink duplicate identifiers and crash
    /// SwiftUI's diffing on the very next tap anywhere on this screen.
    private var allBotSessions: [BotSession] {
        allBots.flatMap { bot in (bot.sessions ?? []).map { BotSession(bot: bot, session: $0) } }
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
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionLabel(title: "Fleet")
                                SkeletonCard(lines: 1)
                            }
                            .padding(.horizontal)
                            VStack(alignment: .leading, spacing: 10) {
                                SectionLabel(title: "Live Sessions")
                                SkeletonList(rowCount: 3)
                            }
                            .padding(.horizontal)
                        }
                        .padding(.vertical)
                    }
                    .background(SwarmTheme.background)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if let error = viewModel.errorMessage {
                                ErrorBanner(message: error).padding(.horizontal)
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    SectionLabel(title: "Fleet")
                                    Spacer()
                                    if let lastUpdatedAt = viewModel.lastUpdatedAt {
                                        TimelineView(.periodic(from: .now, by: 30)) { timeline in
                                            Text("Updated \(relativeTimeFormatter.localizedString(for: lastUpdatedAt, relativeTo: timeline.date))")
                                                .font(.caption2)
                                                .foregroundStyle(SwarmTheme.textMuted)
                                        }
                                    }
                                }
                                PanelCard {
                                    HStack(spacing: 0) {
                                        MetricTile(icon: "server.rack", label: "Bots", value: "\(allBots.count)", tint: .blue)
                                        MetricTile(icon: "dot.radiowaves.left.and.right", label: "Live", value: "\(allSessions.filter { $0.isPlaying == true }.count)", tint: SwarmTheme.ok)
                                        MetricTile(icon: "music.note.list", label: "Queued", value: "\(allSessions.reduce(0) { $0 + ($1.queueCount ?? 0) })", tint: .purple)
                                    }
                                }
                            }
                            .padding(.horizontal)

                            if let ownSession, let ownBotKey {
                                VStack(alignment: .leading, spacing: 10) {
                                    SectionLabel(title: "Your Guild")
                                    NowPlayingQuickControl(session: ownSession, botKey: ownBotKey)
                                    if let topTrack = viewModel.topTrack {
                                        TopTrackTeaser(track: topTrack)
                                    }
                                }
                                .padding(.horizontal)
                                .task(id: "\(ownBotKey):\(ownSession.guildId ?? "")") {
                                    await viewModel.loadTopTrack(botKey: ownBotKey, guildId: ownSession.guildId ?? "")
                                }
                            }

                            if !pinnedBots.pinned.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    SectionLabel(title: "Pinned")
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 10) {
                                            ForEach(pinnedBots.pinned) { pin in
                                                NavigationLink {
                                                    BotDetailView(botKey: pin.botKey, botDisplayName: pin.displayName, guildId: pin.guildId)
                                                } label: {
                                                    Label(pin.displayName, systemImage: "pin.fill")
                                                        .font(.caption.bold())
                                                        .foregroundStyle(SwarmTheme.textPrimary)
                                                        .padding(.horizontal, 12)
                                                        .padding(.vertical, 8)
                                                        .background(SwarmTheme.accent.opacity(0.12), in: Capsule())
                                                        .overlay(Capsule().stroke(SwarmTheme.accent.opacity(0.4), lineWidth: 1))
                                                }
                                                .contextMenu {
                                                    Button(role: .destructive) {
                                                        pinnedBots.toggle(botKey: pin.botKey, guildId: pin.guildId, displayName: pin.displayName)
                                                    } label: {
                                                        Label("Unpin", systemImage: "pin.slash")
                                                    }
                                                }
                                            }
                                        }
                                        .padding(.horizontal)
                                    }
                                }
                            }

                            if !recentBots.visits.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    SectionLabel(title: "Recently Viewed")
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 10) {
                                            ForEach(recentBots.visits) { visit in
                                                NavigationLink {
                                                    BotDetailView(botKey: visit.botKey, botDisplayName: visit.displayName, guildId: visit.guildId)
                                                } label: {
                                                    Text(visit.displayName)
                                                        .font(.caption.bold())
                                                        .foregroundStyle(SwarmTheme.textPrimary)
                                                        .padding(.horizontal, 12)
                                                        .padding(.vertical, 8)
                                                        .background(SwarmTheme.panel, in: Capsule())
                                                        .overlay(Capsule().stroke(SwarmTheme.line, lineWidth: 1))
                                                }
                                            }
                                        }
                                        .padding(.horizontal)
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                SectionLabel(title: "Live Sessions", count: allSessions.count)
                                if allBotSessions.isEmpty {
                                    PanelCard {
                                        EmptyStateView(icon: "waveform.slash", title: "No active sessions right now.")
                                    }
                                } else {
                                    PanelCard(padding: 0) {
                                        VStack(spacing: 0) {
                                            ForEach(Array(allBotSessions.enumerated()), id: \.element.id) { index, entry in
                                                if index > 0 {
                                                    Divider().overlay(SwarmTheme.line)
                                                }
                                                NavigationLink {
                                                    BotDetailView(
                                                        botKey: entry.bot.key,
                                                        botDisplayName: entry.bot.displayName?.isEmpty == false ? entry.bot.displayName! : entry.bot.key,
                                                        guildId: entry.session.guildId ?? ""
                                                    )
                                                } label: {
                                                    SessionRow(session: entry.session)
                                                }
                                                .buttonStyle(.plain)
                                                .contextMenu {
                                                    sessionQuickActions(bot: entry.bot, session: entry.session)
                                                }
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
                    .refreshable {
                        Haptics.light()
                        await viewModel.refresh()
                    }
                    .refreshOnForeground { await viewModel.refresh() }
                }
            }
            .navigationTitle("Dashboard")
            .toolbar {
                if !allBots.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        ShareLink(item: fleetStatusShareText) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .notificationsBell(notificationsViewModel)
            .environmentObject(recentBots)
            .environmentObject(pinnedBots)
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        // Uses the emitted value directly rather than re-reading
        // viewModel.response — @Published's publisher fires from willSet,
        // so the backing property isn't guaranteed updated yet at the point
        // this closure runs.
        .onReceive(viewModel.$response) { newResponse in
            let bots = newResponse?.bots ?? []
            let ownSession = appState.guildId.flatMap { guildId in
                bots.flatMap { $0.sessions ?? [] }.first { $0.guildId == guildId }
            }
            WidgetDataService.shared.update(bots: bots, ownSession: ownSession)
        }
    }

    private var fleetStatusShareText: String {
        let liveCount = allSessions.filter { $0.isPlaying == true }.count
        let queued = allSessions.reduce(0) { $0 + ($1.queueCount ?? 0) }
        var lines = ["SwarmPanel Fleet Status", "\(allBots.count) bots · \(liveCount) live · \(queued) queued"]
        for session in allSessions where session.isPlaying == true {
            let name = session.channelName ?? session.guildName ?? "Guild \(session.guildId ?? "?")"
            lines.append("• \(name): \(session.title?.isEmpty == false ? session.title! : "Untitled")")
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func sessionQuickActions(bot: DashboardBot, session: DashboardSession) -> some View {
        let isPlaying = session.isPlaying == true && session.isPaused != true
        Button {
            Task { await sendQuickAction(isPlaying ? "PAUSE" : "RESUME", bot: bot, session: session) }
        } label: {
            Label(isPlaying ? "Pause" : "Resume", systemImage: isPlaying ? "pause.fill" : "play.fill")
        }
        Button {
            Task { await sendQuickAction("SKIP", bot: bot, session: session) }
        } label: {
            Label("Skip", systemImage: "forward.fill")
        }
    }

    private func sendQuickAction(_ action: String, bot: DashboardBot, session: DashboardSession) async {
        guard let guildId = session.guildId else { return }
        do {
            let _: OKResponse = try await APIClient.shared.post(
                "/api/bots/control",
                body: BotControlRequest(botKey: bot.key, guildId: guildId, action: action, payload: [:])
            )
            Haptics.success()
            toastCenter.success("Sent \(action.capitalized)")
            await viewModel.refresh()
        } catch {
            if !error.isCancellation {
                Haptics.error()
                toastCenter.failure("Action failed")
            }
        }
    }
}

/// A session paired with the bot that reported it. `DashboardSession.id`
/// alone (guildId+channelId) isn't guaranteed unique across bots — two bots
/// covering the same guild would collide — so identity here is keyed on
/// `bot.key` too.
private struct BotSession: Identifiable {
    let bot: DashboardBot
    let session: DashboardSession
    var id: String { "\(bot.key):\(session.id)" }
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
            thumbnail

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

    @ViewBuilder
    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if let thumbnail = session.thumbnail, let url = URL(string: thumbnail) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    placeholderIcon
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(shape)
        } else {
            placeholderIcon
        }
    }

    private var placeholderIcon: some View {
        Image(systemName: "music.note")
            .font(.subheadline)
            .foregroundStyle(SwarmTheme.accent)
            .frame(width: 28, height: 28)
            .background(SwarmTheme.accent.opacity(0.15), in: Circle())
    }
}

private struct NowPlayingQuickControl: View {
    let session: DashboardSession
    let botKey: String
    @State private var isBusy = false

    private var isCurrentlyPlaying: Bool {
        session.isPlaying == true && session.isPaused != true
    }

    var body: some View {
        NowPlayingCard(
            title: session.title ?? "",
            subtitle: session.channelName ?? session.guildName,
            thumbnailURL: session.thumbnail,
            isPlaying: session.isPlaying ?? false,
            isPaused: session.isPaused ?? false,
            positionSeconds: session.positionSeconds ?? 0,
            durationSeconds: session.durationSeconds ?? 0,
            positionObservedAt: session.positionObservedAt,
            mediaSourceLabel: session.mediaSourceLabel,
            cached: session.cached,
            isBusy: isBusy,
            onPause: isCurrentlyPlaying ? { Task { await send("PAUSE") } } : nil,
            onResume: !isCurrentlyPlaying ? { Task { await send("RESUME") } } : nil,
            onSkip: { Task { await send("SKIP") } },
            onSeek: { seconds in Task { await send("SEEK", payload: ["position_seconds": "\(seconds)"]) } }
        )
    }

    private func send(_ action: String, payload: [String: String] = [:]) async {
        guard let guildId = session.guildId else { return }
        isBusy = true
        Haptics.light()
        defer { isBusy = false }
        do {
            let _: OKResponse = try await APIClient.shared.post(
                "/api/bots/control",
                body: BotControlRequest(botKey: botKey, guildId: guildId, action: action, payload: payload)
            )
        } catch {
            // Best-effort — the Controls screen surfaces errors properly;
            // a failed quick-action here just leaves the button re-enabled.
            if !error.isCancellation { Haptics.error() }
        }
    }
}

private struct TopTrackTeaser: View {
    let track: LeaderboardTrack

    var body: some View {
        NavigationLink {
            LeaderboardView()
        } label: {
            PanelCard {
                HStack(spacing: 12) {
                    Image(systemName: "trophy.fill")
                        .font(.subheadline)
                        .foregroundStyle(SwarmTheme.accent)
                        .frame(width: 28, height: 28)
                        .background(SwarmTheme.accent.opacity(0.15), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Top Track")
                            .font(.caption)
                            .foregroundStyle(SwarmTheme.textMuted)
                        Text(track.title?.isEmpty == false ? track.title! : "Unknown title")
                            .font(.subheadline.bold())
                            .foregroundStyle(SwarmTheme.textPrimary)
                            .lineLimit(1)
                    }

                    Spacer()
                    Label("\(track.playCount ?? 0)", systemImage: "play.fill")
                        .font(.caption2)
                        .foregroundStyle(SwarmTheme.textMuted)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            ShareLink(item: "🏆 Top track: \(track.title?.isEmpty == false ? track.title! : "Unknown title") — \(track.playCount ?? 0) plays") {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppState())
        .environmentObject(NotificationsViewModel())
        .environmentObject(ToastCenter())
}
