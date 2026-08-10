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

    var body: some View {
        NavigationStack {
            Form {
                if let error = viewModel.errorMessage {
                    Section { ErrorBanner(message: error) }
                        .listRowBackground(SwarmTheme.panel)
                }
                if let status = viewModel.statusMessage {
                    Section { Text(status).foregroundStyle(SwarmTheme.ok) }
                        .listRowBackground(SwarmTheme.panel)
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
                .listRowBackground(SwarmTheme.panel)

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
                .listRowBackground(SwarmTheme.panel)

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
                    .listRowBackground(SwarmTheme.panel)
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
                .listRowBackground(SwarmTheme.panel)
            }
            .scrollContentBackground(.hidden)
            .background(SwarmTheme.background)
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

#Preview {
    ControlsView()
        .environmentObject(AppState())
        .environmentObject(NotificationsViewModel())
        .environmentObject(ToastCenter())
}
