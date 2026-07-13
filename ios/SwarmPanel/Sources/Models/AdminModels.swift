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

struct GalleryReportStatusBody: Encodable {
    let reportId: Int
    let status: String
}

let galleryReportStatuses = ["open", "reviewed", "dismissed"]
