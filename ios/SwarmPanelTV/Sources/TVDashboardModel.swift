import Foundation

/// Live fleet state for the TV dashboard: the shared /ws "dashboard" push
/// (same key the web and iOS dashboards watch), with a REST fallback poll
/// only while the socket is down -- mirrors the iOS DashboardViewModel.
@MainActor
final class TVDashboardModel: ObservableObject {
    @Published private(set) var dashboard: TVDashboardResponse?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    /// True while `dashboard` is the on-disk snapshot from an earlier run
    /// rather than fresh data -- the view shows "Updated X ago" meanwhile.
    @Published private(set) var isFromCache = false

    private let socket = SwarmLiveSocket.shared
    private let api = APIClient.shared
    private let telemetry = TVTelemetry.shared
    private var pollTask: Task<Void, Never>?
    private var startedAt = Date()
    private var reportedFirstLive = false
    private var fallbackPolls = 0

    private static let cacheKey = "swarmpanel.tv.dashboardSnapshot"
    private static let cacheTimestampKey = "swarmpanel.tv.dashboardSnapshotAt"

    /// Loads the last snapshot from disk so the dashboard appears instantly
    /// on launch, before the network has answered.
    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode(TVDashboardResponse.self, from: data) else { return }
        dashboard = cached
        lastUpdated = UserDefaults.standard.object(forKey: Self.cacheTimestampKey) as? Date
        isFromCache = true
    }

    static func clearCache() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: cacheTimestampKey)
    }

    func start() {
        guard pollTask == nil else { return }
        startedAt = Date()
        reportedFirstLive = false
        if isFromCache {
            let age = lastUpdated.map { Date().timeIntervalSince($0).rounded() }
            telemetry.log("dashboard_cache_shown", value: age)
        }
        socket.watch("dashboard", as: TVDashboardResponse.self) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                self.apply(snapshot, source: "live")
            case .failure(let error):
                self.telemetry.log("dashboard_live_error", ["kind": TVTelemetry.kind(of: error)])
                if self.dashboard == nil { self.errorMessage = error.localizedDescription }
            }
        }
        socket.connect()

        pollTask = Task { [weak self] in
            await self?.loadOnce(source: "rest_initial")
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                guard let self else { break }
                if !self.socket.isConnected {
                    self.fallbackPolls += 1
                    await self.loadOnce(source: "rest_fallback")
                }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        socket.unwatch("dashboard")
        if fallbackPolls > 0 {
            telemetry.log("dashboard_fallback_polls", value: Double(fallbackPolls))
            fallbackPolls = 0
        }
    }

    private func loadOnce(source: String) async {
        let started = Date()
        do {
            let fresh: TVDashboardResponse = try await api.get("/api/dashboard")
            apply(fresh, source: source, requestMs: TVTelemetry.ms(since: started))
        } catch {
            guard !error.isCancellation else { return }
            telemetry.log("dashboard_load_failure", value: TVTelemetry.ms(since: started),
                          ["source": source, "kind": TVTelemetry.kind(of: error)])
            if dashboard == nil {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't load the dashboard."
            }
        }
    }

    private func apply(_ snapshot: TVDashboardResponse, source: String, requestMs: Double? = nil) {
        let wasCached = isFromCache
        dashboard = snapshot
        errorMessage = nil
        isFromCache = false
        let now = Date()
        lastUpdated = now
        if !reportedFirstLive {
            reportedFirstLive = true
            let bots = snapshot.bots ?? []
            telemetry.log("dashboard_first_data", value: TVTelemetry.ms(since: startedAt), [
                "source": source,
                "replaced_cache": wasCached ? "true" : "false",
                "bots": String(bots.count),
                "offline_bots": String(bots.filter { $0.isOffline }.count),
                "request_ms": requestMs.map { String(Int($0)) } ?? "-",
            ])
        }
        // Persist at most every 30s: the live push arrives every couple of
        // seconds and the snapshot only needs to be roughly current for the
        // next launch.
        let lastSaved = UserDefaults.standard.object(forKey: Self.cacheTimestampKey) as? Date
        // tvOS caps an app's UserDefaults at ~500 KB (shared with the
        // telemetry queue and account snapshot), so an unusually large
        // snapshot is skipped rather than risking the whole store.
        if lastSaved.map({ now.timeIntervalSince($0) > 30 }) ?? true,
           let data = try? JSONEncoder().encode(snapshot), data.count < 250_000 {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
            UserDefaults.standard.set(now, forKey: Self.cacheTimestampKey)
        }
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
