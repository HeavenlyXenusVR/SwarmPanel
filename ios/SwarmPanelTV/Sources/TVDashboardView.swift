import SwiftUI
import UIKit

/// The TV version of the web Dashboard: account header, fleet metric strip,
/// Aria's orchestrator card and one card per music bot with its live
/// now-playing session. Read-only -- selecting a card opens that bot's
/// sessions, nothing sends orders.
struct TVDashboardView: View {
    @ObservedObject var session: TVSession
    @ObservedObject var account: TVAccountModel
    @StateObject private var model = TVDashboardModel()
    @ObservedObject private var live = SwarmLiveSocket.shared
    @State private var selectedBot: TVBot?
    @State private var confirmSignOut = false

    private let columns = [GridItem(.adaptive(minimum: 520, maximum: 640), spacing: 40)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                header
                metrics
                if let aria = model.orchestrator {
                    TVAriaCard(bot: aria, accent: account.accent)
                }
                content
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 50)
        }
        .onAppear {
            model.start()
            // A dashboard is meant to stay up on the TV -- don't let the
            // screen saver take over while it's showing.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            model.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(item: $selectedBot) { bot in
            TVBotDetailView(bot: bot, accent: account.accent)
        }
        .alert("Sign out of SwarmPanel?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { session.signOut() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 28) {
            TVAvatar(url: account.profile?.avatarUrl ?? account.profile?.serverIconUrl,
                     name: account.profile?.name ?? session.username, accent: account.accent, size: 96)
            VStack(alignment: .leading, spacing: 6) {
                Text(account.profile?.name ?? session.username)
                    .font(.title2.weight(.bold))
                Text(account.profile?.serverName ?? account.profile?.profileHeadline ?? "SwarmPanel fleet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let updated = model.lastUpdated, model.isFromCache || !live.isConnected {
                // Cached or stale data on screen: say how old it is.
                Text("Updated \(updated, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TVStatusPill(text: live.isConnected ? "Live" : "Reconnecting",
                         color: live.isConnected ? Color(red: 0.49, green: 0.91, blue: 0.53) : .orange)
            Button("Sign Out") {
                TVTelemetry.shared.log("sign_out_prompted")
                confirmSignOut = true
            }
        }
    }

    private var metrics: some View {
        HStack(spacing: 24) {
            TVMetric(label: "Bots Online", value: "\(model.onlineCount) / \(model.musicBots.count)", accent: account.accent)
            TVMetric(label: "Live Sessions", value: "\(model.liveSessionCount)", accent: account.accent)
            TVMetric(label: "Queued", value: "\(model.queueDepth)", accent: account.accent)
            TVMetric(label: "Backup", value: "\(model.backupDepth)", accent: account.accent)
            TVMetric(label: "Guilds", value: "\(model.guildsServed)", accent: account.accent)
            TVMetric(label: "Audio Nodes", value: model.dashboard == nil ? "--" : (model.audioNodesHealthy ? "Healthy" : "Checking"), accent: account.accent)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.dashboard == nil {
            if let error = model.errorMessage {
                Text(error).font(.title3).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 20) {
                    ProgressView()
                    Text("Loading the fleet…").font(.title3).foregroundStyle(.secondary)
                }
            }
        } else if model.musicBots.isEmpty {
            Text("No bots are serving your guild yet.")
                .font(.title3)
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: columns, spacing: 40) {
                ForEach(model.musicBots) { bot in
                    Button {
                        TVTelemetry.shared.log("bot_detail_opened", ["bot": bot.key, "offline": bot.isOffline ? "true" : "false"])
                        selectedBot = bot
                    } label: {
                        TVBotCard(bot: bot, accent: account.accent)
                    }
                    .buttonStyle(.card)
                }
            }
        }
    }
}

// MARK: - Cards

struct TVBotCard: View {
    let bot: TVBot
    let accent: Color

    var body: some View {
        let session = bot.featuredSession
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(bot.name).font(.title3.weight(.bold)).lineLimit(1)
                Spacer()
                TVStatusPill(text: badge.text, color: badge.color)
            }
            HStack(spacing: 20) {
                TVThumbnail(url: session?.thumbnail)
                VStack(alignment: .leading, spacing: 6) {
                    Text(session?.title ?? "Waiting for live playback.")
                        .font(.headline)
                        .lineLimit(2)
                    Text(session?.mediaSourceLabel ?? session?.sessionStateLabel ?? session?.guildName ?? "Idle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let session, (session.durationSeconds ?? 0) > 0 {
                TVPlaybackBar(session: session, accent: accent)
            }
            HStack(spacing: 14) {
                TVChip(text: "\(bot.activePlayingCount ?? 0) live")
                TVChip(text: "\(bot.knownGuildCount ?? 0) guilds")
                TVChip(text: "\(bot.queueDepth ?? 0) queued")
                if let age = bot.heartbeatAgeSeconds { TVChip(text: "heartbeat \(Int(age))s") }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
        .background(Color.black.opacity(0.35))
        .overlay(alignment: .leading) {
            Rectangle().fill(bot.isOffline ? Color.red.opacity(0.7) : accent).frame(width: 6)
        }
        .opacity(bot.isOffline ? 0.6 : 1)
    }

    /// Same precedence as the web card: offline first, then playback state.
    private var badge: (text: String, color: Color) {
        if bot.isOffline { return ("Offline", .red) }
        let session = bot.featuredSession
        if session?.isPlaying == true { return ("Live", Color(red: 0.49, green: 0.91, blue: 0.53)) }
        if session?.isPaused == true { return ("Paused", .yellow) }
        if (bot.heartbeatStatus ?? bot.status ?? "").lowercased().contains("stale") { return ("Stale", .red) }
        return ("Idle", .gray)
    }
}

struct TVAriaCard: View {
    let bot: TVBot
    let accent: Color

    var body: some View {
        let medic = bot.medicSummary
        HStack(spacing: 32) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 56))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Text(bot.name).font(.title3.weight(.bold))
                    Text("Autonomous swarm orchestrator").font(.headline).foregroundStyle(.secondary)
                }
                Text("\(medic?.pendingRepairs ?? 0) pending repairs · \(medic?.pendingInfra ?? 0) infra tasks · \(medic?.criticalHealth ?? 0) critical · \(medic?.recoverableHealth ?? 0) recoverable")
                    .font(.headline)
                HStack(spacing: 14) {
                    if let uptime = bot.uptimeSeconds { TVChip(text: "up " + TVFormat.uptime(uptime)) }
                    if let memory = bot.memoryKb { TVChip(text: "\(Int(memory / 1024)) MB mem") }
                    TVChip(text: "\(bot.recentInteractionCount ?? 0) interactions")
                }
            }
            Spacer()
            TVStatusPill(text: bot.isOffline ? "Offline" : "Online",
                         color: bot.isOffline ? .red : Color(red: 0.49, green: 0.91, blue: 0.53))
        }
        .padding(28)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 24))
        .focusable()
    }
}

struct TVBotDetailView: View {
    let bot: TVBot
    let accent: Color

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(bot.name).font(.largeTitle.weight(.bold))
                let sessions = bot.sessions ?? []
                if sessions.isEmpty {
                    Text("No sessions right now.").font(.title3).foregroundStyle(.secondary)
                }
                ForEach(sessions) { session in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 20) {
                            TVThumbnail(url: session.thumbnail)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.title ?? "Nothing playing").font(.headline).lineLimit(2)
                                Text([session.guildName, session.channelName].compactMap { $0 }.joined(separator: " · "))
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Text("\(session.sessionStateLabel ?? "") · \(session.queueCount ?? 0) queued")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        if (session.durationSeconds ?? 0) > 0 {
                            TVPlaybackBar(session: session, accent: accent)
                        }
                    }
                    .padding(24)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
                    .focusable()
                }
            }
            .padding(60)
        }
    }
}

// MARK: - Small pieces

struct TVPlaybackBar: View {
    let session: DashboardSession
    let accent: Color

    var body: some View {
        // Advances locally once a second between server pushes, like the
        // web dashboard's playback counters.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = Double(session.durationSeconds ?? 0)
            let position = TVFormat.position(of: session, at: context.date)
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(accent)
                            .frame(width: duration > 0 ? geo.size.width * CGFloat(position / duration) : 0)
                    }
                }
                .frame(height: 8)
                HStack {
                    Text(TVFormat.duration(position))
                    Spacer()
                    Text(TVFormat.duration(duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct TVThumbnail: View {
    let url: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08))
            if let url, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note").font(.title).foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "music.note").font(.title).foregroundStyle(.secondary)
            }
        }
        .frame(width: 160, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct TVAvatar: View {
    let url: String?
    let name: String
    let accent: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(accent.opacity(0.35))
            Text(initials).font(.system(size: size * 0.38, weight: .bold))
            if let url, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "SP" : letters.uppercased()
    }
}

struct TVMetric: View {
    let label: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased()).font(.caption.weight(.bold)).foregroundStyle(accent)
            Text(value).font(.title2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct TVStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(color.opacity(0.22), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.7), lineWidth: 2))
    }
}

struct TVChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.1), in: Capsule())
    }
}
