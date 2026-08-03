import Foundation

@MainActor
final class ControlsViewModel: ObservableObject {
    @Published var bots: [BotSummary] = []
    @Published var guilds: [InventoryGuild] = []
    @Published var savedQueues: [SavedQueue] = []
    @Published var controlState: ControlStateSession?

    @Published var selectedBotKey: String = ""
    @Published var guildId: String = ""
    @Published var voiceChannelId: String = ""
    @Published var action: ControlAction = .play
    @Published var sourceURL: String = ""
    @Published var loopMode: String = "queue"
    @Published var filterMode: String = "none"

    @Published var isLoadingBots = true
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private let api = APIClient.shared

    var voiceChannels: [InventoryChannel] {
        guilds.first(where: { $0.id == guildId })?.channels?.filter(\.isVoice) ?? []
    }

    func loadBots(defaultGuildId: String?) async {
        isLoadingBots = true
        defer { isLoadingBots = false }
        do {
            let response: BotsResponse = try await api.get("/api/bots")
            bots = (response.bots ?? []).filter { $0.kind == "music" }
            if selectedBotKey.isEmpty { selectedBotKey = bots.first?.id ?? "" }
            if guildId.isEmpty, let defaultGuildId, !defaultGuildId.isEmpty {
                guildId = defaultGuildId
            }
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load bots."
        }
    }

    /// Switching bots left guildId pointed at whatever guild the PREVIOUS
    /// bot defaulted to — loadInventory()/loadControlStateAndQueues() still
    /// succeed against that guild (it's a real guild, just not one the
    /// newly selected bot serves), so the Guild ID/Voice channel/Text
    /// channel fields all stayed frozen on the old bot's values no matter
    /// which bot was picked, with nothing but a small inline error message
    /// (easy to miss while scrolling) hinting anything was wrong. Re-picks
    /// a guild the newly selected bot actually has a live session in
    /// before refreshing inventory/control-state, mirroring the same fix
    /// already shipped on the web panel's /controls page.
    func botDidChange() async {
        if let guild = await pickGuildForBot(selectedBotKey) {
            guildId = guild
            // The old voiceChannelId belonged to the previous bot/guild
            // pair — clearing it lets loadControlStateAndQueues()'s
            // fill-if-empty pick the NEW bot's actual home channel instead
            // of silently carrying over a channel ID that may not even
            // exist in the new guild.
            voiceChannelId = ""
        }
        await loadInventory()
        await loadControlStateAndQueues()
    }

    private func pickGuildForBot(_ botKey: String) async -> String? {
        guard !botKey.isEmpty else { return nil }
        do {
            let dashboard: DashboardResponse = try await api.get("/api/dashboard")
            guard let bot = dashboard.bots?.first(where: { $0.key == botKey }) else { return nil }
            let sessions = bot.sessions ?? []
            let live = sessions.first(where: { $0.isPlaying == true }) ?? sessions.first
            guard let guild = live?.guildId, !guild.isEmpty else { return nil }
            return guild
        } catch {
            return nil
        }
    }

    func loadInventory() async {
        guard !selectedBotKey.isEmpty else { guilds = []; return }
        do {
            let response: BotInventoryResponse = try await api.get("/api/bots/\(selectedBotKey)/inventory")
            guilds = response.guilds ?? []
            // A guild with no channels listed (Discord fetch failed or this
            // bot's account is in enough guilds that ours fell outside the
            // Discord API's page) isn't a "channels are empty" state — it's
            // "we couldn't confirm channels," so the picker's fallback text
            // field (bound to the same voiceChannelId) stays the only way in.
            if let matched = guilds.first(where: { $0.id == guildId }), let channelsError = matched.channelsError {
                errorMessage = "Couldn't load channels: \(channelsError). Enter the voice channel ID manually below."
            } else if !guildId.isEmpty, !guilds.contains(where: { $0.id == guildId }) {
                errorMessage = "Couldn't confirm this bot's channel list for this guild — enter the voice channel ID manually below."
            }
        } catch {
            guard !error.isCancellation else { return }
            guilds = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load bot inventory."
        }
    }

    func loadControlStateAndQueues() async {
        guard !selectedBotKey.isEmpty, !guildId.isEmpty else { return }
        do {
            let state: ControlStateResponse = try await api.get(
                "/api/bots/\(selectedBotKey)/control-state",
                query: ["guild_id": guildId]
            )
            controlState = state.session
            errorMessage = nil
            // Fill-if-empty, matching the web panel's Controls page — never
            // clobbers a voice channel the operator is mid-picking for a
            // PLAY/SET_HOME order, but this was previously never wired up
            // at all here, so the field just started (and stayed) blank
            // every time until you knew to open the picker and pick the
            // bot's actual home channel yourself.
            if voiceChannelId.isEmpty {
                let homeChannel = state.session?.homeChannelId ?? state.session?.channelId
                if let homeChannel, !homeChannel.isEmpty { voiceChannelId = homeChannel }
            }
            if let loop = state.session?.loopMode, !loop.isEmpty { loopMode = loop }
            if let filter = state.session?.filterMode, !filter.isEmpty { filterMode = filter }
        } catch {
            controlState = nil
            if !error.isCancellation {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load current session."
            }
        }
        do {
            let queues: SavedQueuesResponse = try await api.get(
                "/api/queues",
                query: ["guild_id": guildId, "bot_key": selectedBotKey]
            )
            savedQueues = queues.queues ?? []
        } catch {
            savedQueues = []
        }
    }

    func sendAction() async {
        guard !selectedBotKey.isEmpty, !guildId.isEmpty else { return }
        isSending = true
        statusMessage = nil
        errorMessage = nil
        defer { isSending = false }

        var payload: [String: String] = [:]
        switch action {
        case .play:
            payload["source_url"] = sourceURL
            payload["voice_channel_id"] = voiceChannelId
        case .setHome, .smartRecommend:
            payload["voice_channel_id"] = voiceChannelId
        case .loop:
            payload["loop_mode"] = loopMode
        case .filter:
            payload["filter_mode"] = filterMode
        default:
            break
        }

        do {
            let _: OKResponse = try await api.post(
                "/api/bots/control",
                body: BotControlRequest(botKey: selectedBotKey, guildId: guildId, action: action.rawValue, payload: payload)
            )
            statusMessage = "\(action.label) sent."
            Haptics.success()
            await loadControlStateAndQueues()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Control action failed."
            Haptics.error()
        }
    }

    func saveCurrentQueue(name: String) async {
        guard let items = controlState?.queuePreview, !items.isEmpty else {
            errorMessage = "The live queue is empty — nothing to save."
            return
        }
        do {
            let _: SavedQueueEnvelope = try await api.post(
                "/api/queues",
                body: SavedQueueCreateBody(guildId: guildId, botKey: selectedBotKey, name: name.isEmpty ? "Saved Queue" : name, items: items)
            )
            statusMessage = "Queue saved."
            Haptics.success()
            await loadControlStateAndQueues()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to save queue."
            Haptics.error()
        }
    }

    func loadSavedQueue(_ queue: SavedQueue) async {
        guard !voiceChannelId.isEmpty else {
            errorMessage = "Select a voice channel before loading a saved queue."
            return
        }
        isSending = true
        defer { isSending = false }
        for item in queue.items ?? [] {
            do {
                let _: OKResponse = try await api.post(
                    "/api/bots/control",
                    body: BotControlRequest(
                        botKey: selectedBotKey, guildId: guildId, action: "PLAY",
                        payload: ["source_url": item.videoUrl, "voice_channel_id": voiceChannelId]
                    )
                )
            } catch {
                guard !error.isCancellation else { return }
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load queue."
                return
            }
        }
        statusMessage = "Queued \(queue.itemCount) track(s) from \"\(queue.name)\"."
        Haptics.success()
    }

    func deleteSavedQueue(_ queue: SavedQueue) async {
        do {
            let _: OKResponse = try await api.post("/api/queues/\(queue.id)/delete", body: SavedQueueDeleteBody(guildId: guildId))
            await loadControlStateAndQueues()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to delete queue."
        }
    }
}
