import Foundation

@MainActor
final class DatabasesViewModel: ObservableObject {
    @Published var schemas: [SchemaEntry] = []
    @Published var selectedSchema = ""
    @Published var selectedTable = ""
    @Published var rows: [[String: JSONValue]] = []
    @Published var isLoadingSchemas = true
    @Published var isLoadingRows = false
    @Published var errorMessage: String?

    private let api = APIClient.shared

    var tables: [String] {
        schemas.first(where: { $0.schema == selectedSchema })?.tableNames ?? []
    }

    func loadSchemas() async {
        isLoadingSchemas = true
        defer { isLoadingSchemas = false }
        do {
            let response: SchemasResponse = try await api.get("/api/databases", query: ["include_tables": "true"])
            schemas = response.schemas ?? []
            if selectedSchema.isEmpty, let first = schemas.first {
                selectedSchema = first.schema
                selectedTable = first.tableNames.first ?? ""
            }
            errorMessage = nil
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load schemas."
        }
    }

    func loadRows() async {
        guard !selectedSchema.isEmpty, !selectedTable.isEmpty else { return }
        isLoadingRows = true
        defer { isLoadingRows = false }
        do {
            let response: TableDataResponse = try await api.get(
                "/api/database/data",
                query: ["schema_name": selectedSchema, "table_name": selectedTable, "limit": "100"]
            )
            rows = response.rows ?? []
            errorMessage = nil
        } catch {
            guard !error.isCancellation else { return }
            rows = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load table data."
        }
    }

    @Published var isTruncating = false

    /// Server-side text the admin must type verbatim for a single-table
    /// truncate — mirrors routes.lua's `"TRUNCATE %s.%s"` format exactly.
    func expectedTableConfirmText(schema: String, table: String) -> String {
        "TRUNCATE \(schema).\(table)"
    }

    /// Same, for the whole-schema variant — routes.lua's `"TRUNCATE ALL " .. schema_name`.
    func expectedSchemaConfirmText(schema: String) -> String {
        "TRUNCATE ALL \(schema)"
    }

    @discardableResult
    func truncateTable(schema: String, table: String, confirmText: String, ownerConfirmText: String) async -> Bool {
        isTruncating = true
        defer { isTruncating = false }
        do {
            let response: TruncateResponse = try await api.post(
                "/api/database/truncate-table",
                body: TruncateTableBody(schemaName: schema, tableName: table, confirmText: confirmText, ownerConfirmText: ownerConfirmText)
            )
            errorMessage = nil
            Haptics.warning()
            if response.ok == true { await loadRows() }
            return response.ok == true
        } catch {
            guard !error.isCancellation else { return false }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to truncate table."
            Haptics.error()
            return false
        }
    }

    @discardableResult
    func truncateSchema(schema: String, confirmText: String, ownerConfirmText: String) async -> Bool {
        isTruncating = true
        defer { isTruncating = false }
        do {
            let response: TruncateResponse = try await api.post(
                "/api/database/truncate-schema",
                body: TruncateSchemaBody(schemaName: schema, confirmText: confirmText, ownerConfirmText: ownerConfirmText)
            )
            errorMessage = nil
            Haptics.warning()
            if response.ok == true { await loadSchemas() }
            return response.ok == true
        } catch {
            guard !error.isCancellation else { return false }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to truncate schema."
            Haptics.error()
            return false
        }
    }

    func exportCSV() async -> URL? {
        guard !selectedSchema.isEmpty, !selectedTable.isEmpty else { return nil }
        let allowed = CharacterSet.urlQueryAllowed
        let schema = selectedSchema.addingPercentEncoding(withAllowedCharacters: allowed) ?? selectedSchema
        let table = selectedTable.addingPercentEncoding(withAllowedCharacters: allowed) ?? selectedTable
        do {
            let data = try await api.downloadRaw("/api/database/data?schema_name=\(schema)&table_name=\(table)&limit=1000&format=csv")
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(selectedSchema)_\(selectedTable).csv")
            try data.write(to: tempURL, options: .atomic)
            return tempURL
        } catch {
            guard !error.isCancellation else { return nil }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to export CSV."
            return nil
        }
    }
}
