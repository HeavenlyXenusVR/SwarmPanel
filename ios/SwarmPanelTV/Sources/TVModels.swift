import Foundation

/// TV-only view of the "dashboard" payload (GET /api/dashboard and the
/// "dashboard" live-push key share one shape -- routes.lua's
/// build_dashboard_payload). Declared separately from the iOS app's
/// DashboardBot so the TV screen can read the extra fields it shows
/// (heartbeat age, Aria's process stats and Medic summary, node health)
/// without changing the model the iOS app caches to disk. Session rows reuse
/// the shared DashboardSession from BotModels.swift.
struct TVDashboardResponse: Codable {
    let bots: [TVBot]?
    let sessions: [DashboardSession]?
    let nodeHealth: [String: TVNodeHealth]?

    private enum CodingKeys: String, CodingKey { case bots, sessions, nodeHealth }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bots = try container.decodeIfPresent([TVBot].self, forKey: .bots)
        sessions = try container.decodeIfPresent([DashboardSession].self, forKey: .sessions)
        // The server encodes an empty Lua table as [] rather than {} (see
        // httpd.lua's cjson setting), so a missing node-health map must not
        // fail the whole dashboard decode.
        nodeHealth = try? container.decodeIfPresent([String: TVNodeHealth].self, forKey: .nodeHealth)
    }
}

struct TVNodeHealth: Codable {
    let status: String?
}

struct TVBot: Codable, Identifiable {
    let key: String
    let displayName: String?
    let kind: String?
    let status: String?
    let heartbeatStatus: String?
    let heartbeatAgeSeconds: Double?
    let activePlayingCount: Int?
    let knownGuildCount: Int?
    let queueDepth: Int?
    let backupQueueDepth: Int?
    let sessions: [DashboardSession]?
    // Orchestrator (Aria) only.
    let memoryKb: Double?
    let uptimeSeconds: Double?
    let recentInteractionCount: Int?
    let medicSummary: TVMedicSummary?

    var id: String { key }
    var name: String { displayName ?? key }
    var isOrchestrator: Bool { kind == "orchestrator" }

    /// Same rule as the web dashboard's botIsOffline(): an explicit offline
    /// status, or no heartbeat for over two minutes.
    var isOffline: Bool {
        if (status ?? "").lowercased() == "offline" { return true }
        if let age = heartbeatAgeSeconds, age > 120 { return true }
        return false
    }

    /// The session a card features: whichever guild is actually playing,
    /// else the first known one (web dashboard's bestSession()).
    var featuredSession: DashboardSession? {
        let all = sessions ?? []
        return all.first(where: { $0.isPlaying == true }) ?? all.first
    }
}

struct TVMedicSummary: Codable {
    let pendingRepairs: Int?
    let pendingInfra: Int?
    let criticalHealth: Int?
    let recoverableHealth: Int?
}

enum TVFormat {
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    static func uptime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        let minutes = s / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// position_observed_at arrives as a raw Postgres timestamp in UTC
    /// ("YYYY-MM-DD HH:MM:SS[.ffffff]", sometimes with a "+00" suffix) --
    /// the same format static/app.js's parseSqlTimestampSeconds() handles.
    static func observedAt(_ raw: String?) -> Date? {
        guard var text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let plus = text.range(of: "+", options: .backwards) { text = String(text[..<plus.lowerBound]) }
        if text.hasSuffix("Z") { text.removeLast() }
        text = text.replacingOccurrences(of: "T", with: " ")
        let whole = text.split(separator: ".").first.map(String.init) ?? text
        let fraction = text.split(separator: ".").dropFirst().first.flatMap { Double("0." + $0) } ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = formatter.date(from: whole) else { return nil }
        return date.addingTimeInterval(fraction)
    }

    /// Live playback position: the server-reported position advanced by the
    /// time since it was observed, clamped to the track length.
    static func position(of session: DashboardSession, at now: Date) -> Double {
        var pos = Double(session.positionSeconds ?? 0)
        if session.isPlaying == true, let observed = observedAt(session.positionObservedAt) {
            pos += now.timeIntervalSince(observed)
        }
        if let duration = session.durationSeconds, duration > 0 { pos = min(pos, Double(duration)) }
        return max(0, pos)
    }
}
