import Foundation

enum FleetControlError: LocalizedError {
    case notSignedIn
    case noActiveGuild
    case noActiveSession

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to SwarmPanel first."
        case .noActiveGuild: return "No guild is linked to this account."
        case .noActiveSession: return "Your guild's bot has no active session right now."
        }
    }
}

/// Headless control helper for entry points with no live SwiftUI view around
/// to hold state — Siri/Shortcuts App Intents, mainly, which can run without
/// ever opening the app. Resolves "your guild's bot" the same way
/// DashboardView's ownBotKey/ownSession computed properties do, reading
/// WidgetShared.lastKnownGuildIdKey (mirrored there rather than referenced
/// via AppState directly) since this file is also compiled into the
/// SwarmPanelWidget extension target, which doesn't include AppState.swift.
enum FleetControlService {
    static func ownSession() async throws -> (bot: DashboardBot, session: DashboardSession) {
        guard APIClient.shared.token != nil else { throw FleetControlError.notSignedIn }
        guard let guildId = UserDefaults.standard.string(forKey: WidgetShared.lastKnownGuildIdKey), !guildId.isEmpty else {
            throw FleetControlError.noActiveGuild
        }
        let response: DashboardResponse = try await APIClient.shared.get("/api/dashboard")
        for bot in response.bots ?? [] {
            if let session = (bot.sessions ?? []).first(where: { $0.guildId == guildId }) {
                return (bot, session)
            }
        }
        throw FleetControlError.noActiveSession
    }

    @discardableResult
    static func send(_ action: String, payload: [String: String] = [:]) async throws -> DashboardSession {
        let (bot, session) = try await ownSession()
        guard let guildId = session.guildId else { throw FleetControlError.noActiveSession }
        let _: OKResponse = try await APIClient.shared.post(
            "/api/bots/control",
            body: BotControlRequest(botKey: bot.key, guildId: guildId, action: action, payload: payload)
        )
        return session
    }
}
