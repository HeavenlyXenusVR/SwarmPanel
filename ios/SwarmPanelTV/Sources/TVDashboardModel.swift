import Foundation

/// Live fleet state for the TV dashboard: the shared /ws "dashboard" push
/// (same key the web and iOS dashboards watch), with a REST fallback poll
/// only while the socket is down -- mirrors the iOS DashboardViewModel.
@MainActor
final class TVDashboardModel: ObservableObject {
    @Published private(set) var dashboard: TVDashboardResponse?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?

    private let socket = SwarmLiveSocket.shared
    private let api = APIClient.shared
    private var pollTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        socket.watch("dashboard", as: TVDashboardResponse.self) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                self.apply(snapshot)
            case .failure(let error):
                if self.dashboard == nil { self.errorMessage = error.localizedDescription }
            }
        }
        socket.connect()

        pollTask = Task { [weak self] in
            await self?.loadOnce()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                guard let self else { break }
                if !self.socket.isConnected { await self.loadOnce() }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        socket.unwatch("dashboard")
    }

    private func loadOnce() async {
        do {
            let fresh: TVDashboardResponse = try await api.get("/api/dashboard")
            apply(fresh)
        } catch {
            guard !error.isCancellation else { return }
            if dashboard == nil {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't load the dashboard."
            }
        }
    }

    private func apply(_ snapshot: TVDashboardResponse) {
        dashboard = snapshot
        errorMessage = nil
        lastUpdated = Date()
    }

    // MARK: - Fleet summary (same totals as the web dashboard's metric strip)

    var musicBots: [TVBot] { (dashboard?.bots ?? []).filter { !$0.isOrchestrator } }
    var orchestrator: TVBot? { dashboard?.bots?.first(where: { $0.isOrchestrator }) }
    var onlineCount: Int { musicBots.filter { !$0.isOffline }.count }
    var liveSessionCount: Int {
        musicBots.reduce(0) { $0 + ($1.sessions ?? []).filter { $0.isPlaying == true }.count }
    }
    var queueDepth: Int { musicBots.reduce(0) { $0 + ($1.queueDepth ?? 0) } }
    var backupDepth: Int { musicBots.reduce(0) { $0 + ($1.backupQueueDepth ?? 0) } }
    var guildsServed: Int { musicBots.reduce(0) { $0 + ($1.knownGuildCount ?? 0) } }
    var audioNodesHealthy: Bool {
        ["lavalink", "lavalink2", "lavalink3"].contains { dashboard?.nodeHealth?[$0]?.status == "healthy" }
    }
}
