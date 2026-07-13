import Foundation

/// Generic JSON value for endpoints whose exact shape isn't worth hard-coding
/// into a Decodable struct (system-diagnostics, metrics, stability) — mirrors
/// the web's JsonPanel fallback (components/swarm.jsx: `<pre>{JSON.stringify(data)}</pre>`)
/// rather than guessing at field names that could silently drift.
enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    private var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let value): return value.map(\.anyValue)
        case .object(let value): return value.mapValues(\.anyValue)
        }
    }

    /// JSONSerialization requires the root object to be an Array or
    /// Dictionary — every endpoint this is used for returns a JSON object at
    /// the top level, so that's the only case handled meaningfully; a bare
    /// scalar root just falls back to its raw description.
    var prettyPrinted: String {
        guard JSONSerialization.isValidJSONObject(anyValue),
              let data = try? JSONSerialization.data(withJSONObject: anyValue, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: anyValue)
        }
        return text
    }
}
