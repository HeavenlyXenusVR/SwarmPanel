import Foundation

/// Decode target for the many endpoints that just return `{"ok": true, ...}`
/// with nothing else the caller needs.
struct OKResponse: Decodable {
    let ok: Bool
}
