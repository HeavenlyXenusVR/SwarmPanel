import Foundation

/// Mirrors the web frontend's error-shape handling in frontend/src/api.js:
/// non-2xx responses return `{"detail": ...}` where detail may be a string,
/// a list (FastAPI/Pydantic validation errors), or an object.
struct APIErrorPayload: Decodable {
    let detail: DetailValue?

    enum DetailValue: Decodable {
        case text(String)
        case list([String])
        case other

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
                return
            }
            if let items = try? container.decode([FlexibleDetailItem].self) {
                self = .list(items.map(\.description))
                return
            }
            self = .other
        }

        var message: String {
            switch self {
            case .text(let value): return value
            case .list(let values): return values.joined(separator: "; ")
            case .other: return "Request failed."
            }
        }
    }
}

/// FastAPI validation errors are objects like {"msg": "...", "loc": [...]}. We
/// only care about a human-readable line per item.
private struct FlexibleDetailItem: Decodable, CustomStringConvertible {
    let msg: String?

    var description: String { msg ?? "Invalid request." }
}

enum APIError: LocalizedError {
    case invalidResponse
    case network(Error)
    case decoding(Error)
    case server(statusCode: Int, message: String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an unexpected response."
        case .network(let error):
            return error.localizedDescription
        case .decoding:
            return "Couldn't read the server's response."
        case .server(_, let message):
            return message
        case .unauthorized:
            return "Your session expired. Please log in again."
        }
    }
}
