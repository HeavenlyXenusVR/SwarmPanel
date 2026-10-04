import SwiftUI
import UIKit

struct ControlsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var notificationsViewModel: NotificationsViewModel
    @StateObject private var viewModel = ControlsViewModel()
    @State private var newQueueName = ""
    @State private var deleteQueueTarget: SavedQueue?
    @State private var renameQueueTarget: SavedQueue?
    @State private var renameText = ""
    /// nil = no confirmation showing; true/false = converting to stage/voice.
    @State private var convertToStage: Bool?

    var body: some View {
        NavigationStack {
            Form {
                if let error = viewModel.errorMessage {
                    Section { ErrorBanner(message: error) }
                        .listRowBackground(ResRowBackground())
                }
                if let status = viewModel.statusMessage {
                    Section { Text(status).foregroundStyle(SwarmTheme.ok) }
                        .listRowBackground(ResRowBackground())
                }

                Section {
                    HStack {
                        IconChip(systemName: "server.rack", tint: .blue)
                        Picker("Bot", selection: $viewModel.selectedBotKey) {
                            ForEach(viewModel.bots) { bot in
                                Text(bot.label).tag(bot.id)
                            }
                        }
                        if !viewModel.selectedBotKey.isEmpty {
                            Button {
                                UIPasteboard.general.string = viewModel.selectedBotKey
                                Haptics.success()
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .foregroundStyle(SwarmTheme.textMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        IconChip(systemName: "number", tint: .indigo)
                        // Shows the real Discord guild NAME (resolved from
                        // the selected bot's inventory, same data the voice
                        // channel picker already uses) instead of a bare
                        // numeric ID -- guildId itself (what actually gets
                        // submitted) never changes, only what's displayed.
                        // Falls back to free-text entry when the inventory
                        // hasn't loaded yet or the guild isn't in it (e.g. a
                        // guild the bot hasn't cached channels for).
                        if !viewModel.guilds.isEmpty {
                            Picker("Guild", selection: $viewModel.guildId) {
                                if !viewModel.guilds.contains(where: { $0.id == viewModel.guildId }) && !viewModel.guildId.isEmpty {
                                    Text("Guild \(viewModel.guildId)").tag(viewModel.guildId)
                                }
                                ForEach(viewModel.guilds) { guild in
                                    Text(guild.name?.isEmpty == false ? guild.name! : "Guild \(guild.id)").tag(guild.id)
                                }
                            }
                        } else {
                            TextField("Guild ID", text: $viewModel.guildId)
                                .keyboardType(.numberPad)
                        }
                    }
                } header: {
                    SectionLabel(title: "Bot & Guild")
                }
                .listRowBackground(ResRowBackground())

                Section {
                    HStack {
                        IconChip(systemName: "bolt.fill", tint: .orange)
                        Picker("Action", selection: $viewModel.action) {
                            ForEach(ControlAction.allCases) { action in
                                Text(action.label).tag(action)
                            }
                        }
                    }
                    if viewModel.action.needsSourceURL {
                        TextField("Source URL or search", text: $viewModel.sourceURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if viewModel.action.needsVoiceChannel {
                        if !viewModel.voiceChannels.isEmpty {
                            Picker("Voice Channel", selection: $viewModel.voiceChannelId) {
                                Text("Select a channel").tag("")
                                ForEach(viewModel.voiceChannels) { channel in
                                    Text(channel.name ?? channel.id).tag(channel.id)
                                }
                            }
                        }
                        // Always available, not just a fallback for when the picker
                        // above is empty — Discord's channel list can be incomplete
                        // (bot in many guilds, API pagination, transient fetch
                        // failures), so typing the ID directly is the reliable path.
                        TextField("Voice Channel ID", text: $viewModel.voiceChannelId)
                            .keyboardType(.numberPad)
                    }
                    if viewModel.action.needsLoopMode {
                        Picker("Loop", selection: $viewModel.loopMode) {
                            ForEach(loopModes, id: \.self) { mode in Text(mode.capitalized).tag(mode) }
                        }
                    }
                    if viewModel.action.needsFilterMode {
                        Picker("Filter", selection: $viewModel.filterMode) {
                            ForEach(filterModes, id: \.self) { mode in Text(mode.capitalized).tag(mode) }
                        }
                    }
                    if !viewModel.selectedBotKey.isEmpty && !viewModel.guildId.isEmpty {
                        Text(viewModel.commandPreviewSummary)
                            .font(.caption)
                            .foregroundStyle(SwarmTheme.textMuted)
                    }
                    Button {
                        Task { await viewModel.sendAction() }
                    } label: {
                        HStack {
                            Spacer()
                            if viewModel.isSending {
                                ProgressView().tint(.white)
                            } else {
                                Label("Send Control", systemImage: "paperplane.fill").bold()
                            }
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Rectangle().fill(SwarmTheme.accent.gradient))
                    .disabled(viewModel.isSending || viewModel.selectedBotKey.isEmpty || viewModel.guildId.isEmpty)
                    .opacity(viewModel.isSending || viewModel.selectedBotKey.isEmpty || viewModel.guildId.isEmpty ? 0.5 : 1)
                } header: {
                    SectionLabel(title: "Action")
                }
                .listRowBackground(ResRowBackground())

                if let session = viewModel.controlState {
                    Section {
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
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        StatRow(icon: "music.note.list", tint: .purple, label: "Queue", value: "\(session.queueCount ?? 0)")
                        StatRow(icon: "arrow.triangle.2.circlepath", tint: .indigo, label: "Backup", value: "\(session.backupQueueCount ?? 0)")
                        if let volume = session.volume {
                            StatRow(icon: "speaker.wave.2.fill", tint: .orange, label: "Volume", value: "\(volume)%")
                        }
                        if let loopMode = session.loopMode {
                            StatRow(icon: "repeat", tint: .teal, label: "Loop", value: loopMode.capitalized)
                        }
                        if let filterMode = session.filterMode {
                            StatRow(icon: "slider.horizontal.3", tint: .pink, label: "Filter", value: filterMode.capitalized)
                        }
                        if let pending = session.pendingDirectOrders, pending > 0 {
                            StatRow(icon: "clock.badge.exclamationmark", tint: SwarmTheme.warn, label: "Pending Orders", value: "\(pending)")
                            if let command = session.latestDirectOrder?.command {
                                Text("Waiting on the bot to pick up: \(command)")
                                    .font(.caption2)
                                    .foregroundStyle(SwarmTheme.textMuted)
                            }
                        }
                    } header: {
                        SectionLabel(title: "Current Session")
                    }
                    .listRowBackground(ResRowBackground())
                }

                Section {
                    HStack {
                        TextField("Name this queue", text: $newQueueName)
                        Button("Save") {
                            Task {
                                await viewModel.saveCurrentQueue(name: newQueueName)
                                newQueueName = ""
                            }
                        }
                        .disabled(viewModel.controlState?.queuePreview?.isEmpty ?? true)
                    }
                    if viewModel.savedQueues.isEmpty {
                        EmptyStateView(icon: "list.bullet.rectangle", title: "No saved queues yet.")
                    } else {
                        ForEach(viewModel.savedQueues) { queue in
                            HStack(spacing: 12) {
                                IconChip(systemName: "list.bullet.rectangle.fill", tint: .purple)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(queue.name).font(.subheadline.bold())
                                    Text("\(queue.itemCount) tracks").font(.caption).foregroundStyle(SwarmTheme.textMuted)
                                }
                                Spacer()
                                Button {
                                    Task { await viewModel.loadSavedQueue(queue) }
                                } label: {
                                    Image(systemName: "play.circle.fill").foregroundStyle(SwarmTheme.accent)
                                }
                                .disabled(viewModel.isSending)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deleteQueueTarget = queue
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    renameText = queue.name
                                    renameQueueTarget = queue
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .leading) {
                                ShareLink(item: shareText(for: queue)) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .tint(SwarmTheme.accent)
                            }
                        }
                    }
                } header: {
                    SectionLabel(title: "Saved Queues", count: viewModel.savedQueues.count)
                }
                .listRowBackground(ResRowBackground())

                // Every bot in the selected guild at once -- mirrors the web
                // Controls page's Guild Overview.
                Section {
                    Button {
                        Task { await viewModel.loadGuildOverview() }
                    } label: {
                        HStack {
                            Label(viewModel.guildOverview.isEmpty ? "Load Guild Overview" : "Refresh Overview", systemImage: "square.grid.3x3")
                            Spacer()
                            if viewModel.isLoadingOverview { ProgressView() }
                        }
                    }
                    .disabled(viewModel.isLoadingOverview || viewModel.guildId.isEmpty)
                    .tint(SwarmTheme.accent)

                    ForEach(viewModel.guildOverview) { bot in
                        GuildOverviewRow(bot: bot) { action in
                            Task { await viewModel.sendOverviewAction(action, to: bot) }
                        }
                    }
                } header: {
                    SectionLabel(title: "Guild Overview", count: viewModel.guildOverview.isEmpty ? nil : viewModel.guildOverview.filter(\.isActive).count)
                } footer: {
                    if !viewModel.guildOverview.isEmpty {
                        Text("Active bots in guild \(viewModel.guildOverviewGuildId ?? "") are counted in the header.")
                    }
                }
                .listRowBackground(ResRowBackground())

                Section {
                    Button {
                        convertToStage = true
                    } label: {
                        Label("Convert to Stage Channels", systemImage: "person.wave.2")
                    }
                    Button {
                        convertToStage = false
                    } label: {
                        Label("Convert to Voice Channels", systemImage: "speaker.wave.2")
                    }
                    if viewModel.isConverting {
                        HStack { ProgressView(); Text("Converting…").foregroundStyle(SwarmTheme.textMuted) }
                    }
                } header: {
                    SectionLabel(title: "Stage / Voice Channels")
                } footer: {
                    Text("Converts every bot's home channel in the selected guild. Names, category, position and permissions are kept.")
                }
                .disabled(viewModel.isConverting || viewModel.guildId.isEmpty)
                .tint(SwarmTheme.accent)
                .listRowBackground(ResRowBackground())
            }
            .scrollContentBackground(.hidden)
            .background(ResonanceBackdrop().ignoresSafeArea())
            .navigationTitle("Controls")
            .task {
                await viewModel.loadBots(defaultGuildId: appState.guildId)
                await viewModel.loadInventory()
                await viewModel.loadControlStateAndQueues()
            }
            // Old single-parameter onChange signature — deprecated but still
            // available in iOS 17+, and required (not just preferred) for the
            // iOS 16.0 deployment target used here (the zero-parameter overload
            // is iOS 17+ only and would fail to build against iOS 16).
            .onChange(of: viewModel.selectedBotKey) { _ in
                Task { await viewModel.botDidChange() }
            }
            .onChange(of: viewModel.guildId) { _ in
                Task { await viewModel.loadControlStateAndQueues() }
            }
            .refreshable {
                Haptics.light()
                await viewModel.loadControlStateAndQueues()
            }
            .refreshOnForeground { await viewModel.loadControlStateAndQueues() }
            .onDisappear { viewModel.stopWatchingControlState() }
            .notificationsBell(notificationsViewModel)
            .confirmationDialog(
                "Delete \"\(deleteQueueTarget?.name ?? "")\"?",
                isPresented: Binding(get: { deleteQueueTarget != nil }, set: { if !$0 { deleteQueueTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let target = deleteQueueTarget { Task { await viewModel.deleteSavedQueue(target) } }
                    deleteQueueTarget = nil
                }
                Button("Cancel", role: .cancel) { deleteQueueTarget = nil }
            }
            // Same warning as the web panel: Discord can't convert a channel
            // in place, so this deletes and recreates each one.
            .confirmationDialog(
                convertToStage == true ? "Convert to stage channels?" : "Convert to voice channels?",
                isPresented: Binding(get: { convertToStage != nil }, set: { if !$0 { convertToStage = nil } }),
                titleVisibility: .visible
            ) {
                Button("Convert", role: .destructive) {
                    if let toStage = convertToStage { Task { await viewModel.convertChannels(toStage: toStage) } }
                    convertToStage = nil
                }
                Button("Cancel", role: .cancel) { convertToStage = nil }
            } message: {
                Text("Discord can't convert a channel in place, so each bot's home channel is deleted and recreated with the same name, category, position and permissions. Anyone connected is briefly disconnected and the channel's chat history is lost.")
            }
            .alert(
                "Rename Queue",
                isPresented: Binding(get: { renameQueueTarget != nil }, set: { if !$0 { renameQueueTarget = nil } })
            ) {
                TextField("Queue name", text: $renameText)
                Button("Save") {
                    if let target = renameQueueTarget { Task { await viewModel.renameSavedQueue(target, to: renameText) } }
                    renameQueueTarget = nil
                }
                Button("Cancel", role: .cancel) { renameQueueTarget = nil }
            }
        }
    }

    private func shareText(for queue: SavedQueue) -> String {
        let lines = (queue.items ?? []).prefix(20).enumerated().map { index, item in
            "\(index + 1). \(item.title?.isEmpty == false ? item.title! : item.videoUrl)"
        }
        return "🎵 \(queue.name) (\(queue.itemCount) tracks)\n" + lines.joined(separator: "\n")
    }
}

/// One bot's row in the Guild Overview section.
private struct GuildOverviewRow: View {
    let bot: ControlMatrixBot
    let onAction: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(bot.label).font(.headline).foregroundStyle(SwarmTheme.textPrimary)
                Spacer()
                Text(stateLabel)
                    .font(.caption.bold())
                    .foregroundStyle(stateColor)
            }
            if let error = bot.error {
                Text(error).font(.caption).foregroundStyle(SwarmTheme.danger)
            } else {
                Text(channelLabel).font(.caption).foregroundStyle(SwarmTheme.textMuted)
                if let title = bot.session?.title, !title.isEmpty {
                    Text(title).font(.subheadline).lineLimit(1).foregroundStyle(SwarmTheme.textPrimary)
                }
                HStack {
                    Text("\(bot.session?.queueCount ?? 0) queued").font(.caption).foregroundStyle(SwarmTheme.textMuted)
                    Spacer()
                    if bot.isActive {
                        Button(bot.session?.isPaused == true ? "Resume" : "Pause") {
                            onAction(bot.session?.isPaused == true ? "RESUME" : "PAUSE")
                        }
                        .buttonStyle(.bordered)
                        Button("Skip") { onAction("SKIP") }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var stateLabel: String {
        if bot.error != nil { return "Unavailable" }
        if let label = bot.session?.sessionStateLabel, !label.isEmpty { return label }
        return bot.session?.isPlaying == true ? "Playing" : "Idle"
    }

    private var stateColor: Color {
        if bot.error != nil { return SwarmTheme.danger }
        if bot.session?.isPlaying == true { return SwarmTheme.ok }
        if bot.session?.isPaused == true { return SwarmTheme.warn }
        return SwarmTheme.textMuted
    }

    private var channelLabel: String {
        if let name = bot.session?.channelName, !name.isEmpty { return "#\(name)" }
        if let id = bot.session?.channelId, !id.isEmpty { return "Channel \(id)" }
        return "Not connected"
    }
}

#Preview {
    ControlsView()
        .environmentObject(AppState())
        .environmentObject(NotificationsViewModel())
        .environmentObject(ToastCenter())
}
