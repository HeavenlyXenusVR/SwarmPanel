import Foundation

/// POST /api/session/login body for the TV. disable_admin_mode asks the
/// server for a session with admin mode off (routes.lua's login route):
/// the TV never runs in admin mode, and -- unlike calling
/// /api/session/admin-mode -- this doesn't change the owner's saved
/// admin-mode preference for the web and iOS apps.
private struct TVLoginRequest: Encodable {
    let username: String
    let password: String
    let disableAdminMode: Bool
}

/// Sign-in state for the TV app. Same token lifecycle as the iOS app's
/// AppState, trimmed to what a read-only dashboard needs: a bearer token in
/// the Keychain (via APIClient), a rolling refresh through GET /api/session
/// so a TV left on the dashboard never hits the token's expiry, and a
/// return to the sign-in screen on any 401.
@MainActor
final class TVSession: ObservableObject {
    @Published private(set) var isAuthenticated: Bool
    @Published private(set) var username = ""
    @Published var errorMessage: String?
    @Published private(set) var isWorking = false

    private let api = APIClient.shared
    private var refreshTask: Task<Void, Never>?

    init() {
        isAuthenticated = APIClient.shared.token != nil
        api.onUnauthorized = { [weak self] in
            Task { @MainActor in self?.signOut() }
        }
        if isAuthenticated {
            startRefreshLoop()
            Task { await refresh() }
        }
    }

    func signIn(username: String, password: String) async {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !password.isEmpty else {
            errorMessage = "Enter your username and password."
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let payload: SessionPayload = try await api.post(
                "/api/session/login",
                body: TVLoginRequest(username: name, password: password, disableAdminMode: true)
            )
            guard let token = payload.token else {
                errorMessage = "The server didn't return a session."
                return
            }
            api.token = token
            self.username = payload.username ?? name
            isAuthenticated = true
            startRefreshLoop()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Sign-in failed."
        }
    }

    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        SwarmLiveSocket.shared.disconnect()
        api.token = nil
        username = ""
        isAuthenticated = false
    }

    /// A network hiccup keeps the current session; only an explicit 401
    /// (APIClient.onUnauthorized) signs out.
    func refresh() async {
        do {
            let payload: SessionPayload = try await api.get("/api/session")
            if payload.authenticated == false {
                signOut()
                return
            }
            if let token = payload.token { api.token = token }
            if let name = payload.username { username = name }
        } catch {
            // Retry on the next tick.
        }
    }

    private func startRefreshLoop() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30 * 60))
                if Task.isCancelled { break }
                await self?.refresh()
            }
        }
    }
}
