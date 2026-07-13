import Foundation

/// GET /api/exports returns {"ok": true, "enabled": bool, "snapshots": [...]}
/// — owner-only, opt-in scheduled CSV snapshots (app/routers/exports.py).
struct ExportsResponse: Decodable {
    let enabled: Bool?
    let snapshots: [ExportSnapshot]?
}

struct ExportSnapshot: Decodable, Identifiable {
    let date: String
    let files: [ExportFile]?

    var id: String { date }
}

struct ExportFile: Decodable, Identifiable {
    let name: String
    let sizeBytes: Int?

    var id: String { name }

    var sizeDescription: String {
        guard let sizeBytes else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}
