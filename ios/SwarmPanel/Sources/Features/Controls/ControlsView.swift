import SwiftUI
import UIKit

struct ControlsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var notificationsViewModel: NotificationsViewModel
    @StateObject private var viewModel = ControlsViewModel()
    @State private var newQueueName = ""
    @State private var deleteQueueTarget: SavedQueue?

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
                    TextField("Guild ID", text: $viewModel.guildId)
                        .keyboardType(.numberPad)
                } header: {
                    SectionLabel(title: "Bot & Guild")
                }
                .listRowBackground(SwarmTheme.panel)

                Section {
                    Picker("Action", selection: $viewModel.action) {
                        ForEach(ControlAction.allCases) { action in
                            Text(action.label).tag(action)
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
                    Button {
                        Task { await viewModel.sendAction() }
                    } label: {
                        HStack {
                            Spacer()
                            if viewModel.isSending { ProgressView() } else { Text("Send Control").bold() }
                            Spacer()
                        }
                    }
                    .disabled(viewModel.isSending || viewModel.selectedBotKey.isEmpty || viewModel.guildId.isEmpty)
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
                        LabeledContent("Queue", value: "\(session.queueCount ?? 0)")
                        LabeledContent("Backup", value: "\(session.backupQueueCount ?? 0)")
                        if let volume = session.volume {
                            LabeledContent("Volume", value: "\(volume)%")
                        }
                        if let loopMode = session.loopMode {
                            LabeledContent("Loop", value: loopMode.capitalized)
                        }
                        if let filterMode = session.filterMode {
                            LabeledContent("Filter", value: filterMode.capitalized)
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
                            HStack {
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
                Task {
                    await viewModel.loadInventory()
                    await viewModel.loadControlStateAndQueues()
                }
            }
            .onChange(of: viewModel.guildId) { _ in
                Task { await viewModel.loadControlStateAndQueues() }
            }
            .refreshable {
                Haptics.light()
                await viewModel.loadControlStateAndQueues()
            }
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
        }
    }
}

#Preview {
    ControlsView()
        .environmentObject(AppState())
        .environmentObject(NotificationsViewModel())
        .environmentObject(ToastCenter())
}
