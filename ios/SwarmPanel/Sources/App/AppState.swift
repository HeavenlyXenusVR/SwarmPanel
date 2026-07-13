import Foundation

/// App-wide session state: auth status, role flags, and the rolling
/// token-refresh loop. One instance lives for the app's lifetime, injected
/// into the view hierarchy as an environment object.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isBootstrapping = true
    @Published private(set) var username = ""
    @Published private(set) var role = ""
    @Published private(set) var guildId: String?
    @Published private(set) var isOwner = false
    @Published private(set) var isAdmin = false
    @Published private(set) var isModerator = false
    @Published private(set) var canGallery = false
    @Published var errorMessage: String?

    private let api = APIClient.shared
    private var refreshTask: Task<Void, Never>?

    init() {
        api.onUnauthorized = { [weak self] in
            Task { @MainActor in self?.handleUnauthorized() }
        }
    }

    /// Called once at app launch. If a token is already stored, validates and
    /// rolls it forward via GET /api/session rather than forcing a fresh login.
    func bootstrap() async {
        isBootstrapping = true
        defer { isBootstrapping = false }
        guard api.token != nil else { return }
        await refreshSession()
    }

    func login(username: String, password: String, guildId: String?) async {
        errorMessage = nil
        let trimmedGuildId = guildId?.trimmingCharacters(in: .whitespaces)
        do {
            let payload: SessionPayload = try await api.post(
                "/api/session/login",
                body: LoginRequest(username: username, password: password, guildId: trimmedGuildId?.isEmpty == false ? trimmedGuildId : nil)
            )
            apply(payload)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Login failed."
        }
    }

    func register(username: String, guildId: String, password: String, email: String, verificationWebhookUrl: String) async {
        errorMessage = nil
        do {
            let payload: SessionPayload = try await api.post(
                "/api/session/register",
                body: RegisterRequest(
                    username: username,
                    guildId: guildId,
                    password: password,
                    email: email.isEmpty ? nil : email,
                    verificationWebhookUrl: verificationWebhookUrl.isEmpty ? nil : verificationWebhookUrl
                )
            )
            apply(payload)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Registration failed."
        }
    }

    func logout() {
        api.token = nil
        stopRefreshLoop()
        isAuthenticated = false
        username = ""
        role = ""
        guildId = nil
        isOwner = false
        isAdmin = false
        isModerator = false
        canGallery = false
    }

    /// Rolling refresh: GET /api/session re-issues a fresh full-TTL bearer
    /// token given the current still-valid one (app/routers/session.py) — no
    /// separate refresh-token endpoint exists or is needed. A network hiccup
    /// here must not log the user out; only an explicit 401 does that, via
    /// APIClient.onUnauthorized.
    func refreshSession() async {
        do {
            let payload: SessionPayload = try await api.get("/api/session")
            if payload.authenticated == false {
                handleUnauthorized()
                return
            }
            apply(payload)
        } catch {
            // Ignore — keep the existing session state and retry on the next tick.
        }
    }

    private func apply(_ payload: SessionPayload) {
        if let token = payload.token { api.token = token }
        username = payload.username ?? username
        role = payload.role ?? role
        guildId = payload.guildId ?? payload.accountGuildId ?? guildId
        isOwner = payload.siteOwner ?? isOwner
        isAdmin = payload.adminMode ?? isAdmin
        isModerator = payload.moderator ?? isModerator
        canGallery = payload.imageGalleryOwner ?? canGallery
        isAuthenticated = true
        startRefreshLoop()
    }

    private func handleUnauthorized() {
        api.token = nil
        stopRefreshLoop()
        isAuthenticated = false
    }

    private func startRefreshLoop() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30 * 60))
                if Task.isCancelled { break }
                await self.refreshSession()
            }
        }
    }

    private func stopRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
