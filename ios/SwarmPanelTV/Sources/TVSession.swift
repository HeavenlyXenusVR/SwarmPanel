import Foundation

/// POST /api/session/login body for the TV.
/// - disable_admin_mode: a session with admin mode off (the TV never runs
///   in admin mode) without changing the owner's saved admin-mode choice.
/// - remember_device + client: a long-lived device session (routes.lua's
///   token_ttl) that each refresh renews, so closing the app -- or leaving
///   the TV off for days -- doesn't mean signing in again.
private struct TVLoginRequest: Encodable {
    let username: String
    let password: String
    let disableAdminMode = true
    let rememberDevice = true
    let client = "tvos"
}

/// Sign-in state for the TV app. The bearer token lives in the Keychain
/// (APIClient), so a relaunch restores the session immediately -- the
/// dashboard shows at once from the on-disk cache while GET /api/session
/// renews the token in the background. Renewal also runs every 30 minutes
/// and every time the app comes back to the foreground (a suspended app's
/// timers don't run). Only an explicit 401 signs out; a network failure
/// keeps the session.
@MainActor
final class TVSession: ObservableObject {
    @Published private(set) var isAuthenticated: Bool
    @Published private(set) var username: String
    @Published var errorMessage: String?
    @Published private(set) var isWorking = false

    private static let usernameKey = "swarmpanel.tv.username"
    private let api = APIClient.shared
    private let telemetry = TVTelemetry.shared
    private var refreshTask: Task<Void, Never>?
    private var lastRefresh: Date?
    private var signingOutByUser = false

    init() {
        isAuthenticated = APIClient.shared.token != nil
        username = UserDefaults.standard.string(forKey: Self.usernameKey) ?? ""
        api.onUnauthorized = { [weak self] in
            Task { @MainActor in self?.sessionExpired() }
        }
        telemetry.start()
        telemetry.log("app_launch", ["restored_session": isAuthenticated ? "true" : "false"])
        if isAuthenticated {
            startRefreshLoop()
            Task { await refresh(reason: "launch") }
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
        let started = Date()
        telemetry.log("login_attempt")
        do {
            let payload: SessionPayload = try await api.post(
                "/api/session/login",
                body: TVLoginRequest(username: name, password: password)
            )
            guard let token = payload.token else {
                errorMessage = "The server didn't return a session."
                telemetry.log("login_failure", ["kind": "no_token"])
                return
            }
            api.token = token
            self.username = payload.username ?? name
            UserDefaults.standard.set(self.username, forKey: Self.usernameKey)
            isAuthenticated = true
            lastRefresh = Date()
            startRefreshLoop()
            telemetry.log("login_success", value: TVTelemetry.ms(since: started),
                          ["expires_in_s": payload.expiresIn.map(String.init) ?? "?"])
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Sign-in failed."
            telemetry.log("login_failure", value: TVTelemetry.ms(since: started), ["kind": TVTelemetry.kind(of: error)])
        }
    }

    /// User-initiated sign-out.
    func signOut() {
        signingOutByUser = true
        telemetry.log("sign_out")
        endSession()
        signingOutByUser = false
        Task { await telemetry.flush() }
    }

    /// Any 401 from the API: the stored token is no longer valid.
    private func sessionExpired() {
        guard isAuthenticated, !signingOutByUser else { return }
        telemetry.log("session_expired")
        endSession()
        errorMessage = "Your session expired. Please sign in again."
    }

    private func endSession() {
        refreshTask?.cancel()
        refreshTask = nil
        SwarmLiveSocket.shared.disconnect()
        api.token = nil
        isAuthenticated = false
        TVDashboardModel.clearCache()
        TVAccountModel.clearCache()
    }

    /// Foreground: renew straight away unless we just did. A TV app can sit
    /// suspended for days, and its 30-minute timer doesn't run meanwhile.
    func appBecameActive() {
        guard isAuthenticated else { return }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 5 * 60 { return }
        Task { await refresh(reason: "foreground") }
    }

    /// Renews the token via GET /api/session. A network hiccup keeps the
    /// current session; only an explicit 401 (APIClient.onUnauthorized)
    /// signs out.
    func refresh(reason: String) async {
        let started = Date()
        do {
            let payload: SessionPayload = try await api.get("/api/session")
            if payload.authenticated == false {
                sessionExpired()
                return
            }
            if let token = payload.token { api.token = token }
            if let name = payload.username {
                username = name
                UserDefaults.standard.set(name, forKey: Self.usernameKey)
            }
            lastRefresh = Date()
            telemetry.log("session_refresh", value: TVTelemetry.ms(since: started), ["reason": reason])
        } catch {
            guard !error.isCancellation else { return }
            telemetry.log("session_refresh_failure", value: TVTelemetry.ms(since: started),
                          ["reason": reason, "kind": TVTelemetry.kind(of: error)])
        }
    }

    private func startRefreshLoop() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30 * 60))
                if Task.isCancelled { break }
                await self?.refresh(reason: "timer")
            }
        }
    }
}
