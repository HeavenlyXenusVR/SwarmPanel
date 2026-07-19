import Foundation

// MARK: - Schema/table listing (GET /api/databases?include_tables=true)

struct SchemasResponse: Decodable {
    let schemas: [SchemaEntry]?
}

struct SchemaEntry: Decodable, Identifiable {
    let schema: String
    let tables: [JSONValue]?

    var id: String { schema }

    /// Table entries aren't a fixed shape server-side — mirrors the web's
    /// tableName() helper (frontend/src/pages/DatabasesPage.jsx) checking the
    /// same handful of possible key names, falling back to a bare string.
    var tableNames: [String] {
        (tables ?? []).map { entry in
            switch entry {
            case .string(let name):
                return name
            case .object(let fields):
                if case .string(let name)? = fields["name"] { return name }
                if case .string(let name)? = fields["table_name"] { return name }
                if case .string(let name)? = fields["TABLE_NAME"] { return name }
                return ""
            default:
                return ""
            }
        }.filter { !$0.isEmpty }
    }
}

// MARK: - Row data (GET /api/database/data)

struct TableDataResponse: Decodable {
    let ok: Bool?
    let rows: [[String: JSONValue]]?
    let count: Int?
}
