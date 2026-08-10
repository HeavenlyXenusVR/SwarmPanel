import Foundation

// MARK: - Audit Log (GET /api/audit-log) — moderator + admin

struct AuditLogEnvelope: Decodable {
    let data: AuditLogData
}

struct AuditLogData: Decodable {
    let entries: [AuditLogEntry]?
    let total: Int?
}

struct AuditLogEntry: Decodable, Identifiable {
    let id: Int
    let actorUsername: String?
    let action: String
    let targetType: String?
    let targetId: String?
    let details: String?
    let createdAt: String?

    /// One row per changed field. `details` is server-produced JSON of the
    /// shape `{"before": {...}, "after": {...}}` (audit.lua's diff_details) --
    /// mirrors the web panel's Audit Log diff rendering (added after the raw
    /// `details` string was previously just dumped verbatim, unreadable for
    /// anything but the shortest actions). Returns nil (caller falls back to
    /// showing the raw string) for any entry whose details aren't that shape,
    /// e.g. plain string details like "succeeded_ids=3 failed=0".
    var diffPairs: [(key: String, before: String, after: String)]? {
        guard let details, let data = details.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              case .object(let before)? = decoded["before"],
              case .object(let after)? = decoded["after"] else {
            return nil
        }
        let keys = Set(before.keys).union(after.keys).sorted()
        guard !keys.isEmpty else { return nil }
        return keys.map { key in
            (key: key, before: before[key]?.displayString ?? "—", after: after[key]?.displayString ?? "—")
        }
    }
}

// MARK: - Alert Rules (GET /api/alert-rules) — read: moderator + admin;
// create/update/delete: admin (owner) only.

struct AlertRulesResponse: Decodable {
    let rules: [AlertRule]?
}

struct AlertRuleEnvelope: Decodable {
    let rule: AlertRule
}

struct AlertRule: Decodable, Identifiable {
    let id: Int
    let ruleType: String
    let thresholdMinutes: Int
    let enabled: Bool
    let escalationMinutes: Int?
    let escalateEmail: Bool?
}

struct AlertRuleCreateBody: Encodable {
    let ruleType: String
    let thresholdMinutes: Int
    let enabled: Bool
    let escalationMinutes: Int?
    let escalateEmail: Bool?
}

struct AlertRuleToggleBody: Encodable {
    let enabled: Bool
}

let alertRuleTypes = ["bot_offline", "queue_stuck", "stale_metrics", "recovery_pending"]

// MARK: - Lumisound moderation (GET /api/lumisound/admin) — moderator + admin

struct LumisoundAdminEnvelope: Decodable {
    let data: LumisoundAdminData
}

struct LumisoundAdminData: Decodable {
    let users: [LumisoundUser]?
    let uploads: [LumisoundUpload]?
    let bugReports: [LumisoundBugReport]?
}

struct LumisoundUser: Decodable, Identifiable {
    let id: Int
    let username: String?
    let isActive: Bool?
}

struct LumisoundUpload: Decodable, Identifiable {
    let id: Int
    let filename: String?
    let title: String?
    let username: String?
}

struct LumisoundBugReport: Decodable, Identifiable {
    let id: Int
    let category: String?
    let description: String?
    let status: String?
    let username: String?
}

struct LumisoundUserActiveBody: Encodable {
    let userId: Int
    let active: Bool
}

struct LumisoundUploadDeleteBody: Encodable {
    let uploadId: Int
}

struct LumisoundBugReportStatusBody: Encodable {
    let reportId: Int
    let status: String
}

// MARK: - Gallery moderation (GET /api/image-gallery/admin) — owner
// (image-gallery-owner) only; comment-delete/report-status also accept
// moderators, but the read endpoint itself stays owner-only, so a
// moderator-only account has no data source to moderate from in-app.

struct GalleryAdminEnvelope: Decodable {
    let data: GalleryAdminData
}

struct GalleryAdminData: Decodable {
    let comments: [GalleryComment]?
    let reports: [GalleryReport]?
}

struct GalleryComment: Decodable, Identifiable {
    let id: Int
    let body: String?
    let username: String?
    let mediaTitle: String?
}

struct GalleryReport: Decodable, Identifiable {
    let id: Int
    let reason: String?
    let details: String?
    let status: String?
    let username: String?
    let mediaTitle: String?
}

struct GalleryCommentDeleteBody: Encodable {
    let commentId: Int
}

struct GalleryBulkDeleteBody: Encodable {
    let ids: [Int]
}

struct GalleryReportStatusBody: Encodable {
    let reportId: Int
    let status: String
}

let galleryReportStatuses = ["open", "reviewed", "dismissed"]

// MARK: - Live event feed (GET /api/events) — admin only

struct EventsResponse: Decodable {
    let events: [FeedEvent]?
}

struct FeedEvent: Decodable, Identifiable {
    let timestamp: String?
    let source: String?
    let title: String?
    let description: String?
    let type: String?

    var id: String { "\(timestamp ?? "")-\(source ?? "")-\(title ?? "")" }
}
