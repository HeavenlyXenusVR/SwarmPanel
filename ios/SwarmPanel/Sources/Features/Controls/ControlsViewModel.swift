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
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load bots."
        }
    }

    func loadInventory() async {
        guard !selectedBotKey.isEmpty else { guilds = []; return }
        do {
            let response: BotInventoryResponse = try await api.get("/api/bots/\(selectedBotKey)/inventory")
            guilds = response.guilds ?? []
        } catch {
            guilds = []
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
        } catch {
            controlState = nil
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
            await loadControlStateAndQueues()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Control action failed."
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
            await loadControlStateAndQueues()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to save queue."
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
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load queue."
                return
            }
        }
        statusMessage = "Queued \(queue.itemCount) track(s) from \"\(queue.name)\"."
    }

    func deleteSavedQueue(_ queue: SavedQueue) async {
        do {
            let _: OKResponse = try await api.post("/api/queues/\(queue.id)/delete", body: SavedQueueDeleteBody(guildId: guildId))
            await loadControlStateAndQueues()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to delete queue."
        }
    }
}
