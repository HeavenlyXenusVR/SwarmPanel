import Foundation

@MainActor
final class AlertRulesViewModel: ObservableObject {
    @Published var rules: [AlertRule] = []
    @Published var isLoading = true
    @Published var isSaving = false
    @Published var errorMessage: String?

    private let api = APIClient.shared

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: AlertRulesResponse = try await api.get("/api/alert-rules")
            rules = response.rules ?? []
            errorMessage = nil
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load alert rules."
        }
    }

    func create(ruleType: String, thresholdMinutes: Int) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let _: AlertRuleEnvelope = try await api.post(
                "/api/alert-rules",
                body: AlertRuleCreateBody(ruleType: ruleType, thresholdMinutes: thresholdMinutes, enabled: true)
            )
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to create alert rule."
        }
    }

    func toggle(_ rule: AlertRule) async {
        do {
            let _: AlertRuleEnvelope = try await api.post(
                "/api/alert-rules/\(rule.id)/update",
                body: AlertRuleToggleBody(enabled: !rule.enabled)
            )
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to update alert rule."
        }
    }

    func delete(_ rule: AlertRule) async {
        do {
            let _: OKResponse = try await api.post("/api/alert-rules/\(rule.id)/delete")
            await load()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to delete alert rule."
        }
    }
}
