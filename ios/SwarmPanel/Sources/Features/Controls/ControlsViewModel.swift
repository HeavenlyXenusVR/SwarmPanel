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
