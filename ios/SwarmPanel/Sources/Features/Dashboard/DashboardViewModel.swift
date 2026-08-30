import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var response: DashboardResponse?
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var topTrack: LeaderboardTrack?
    /// When set, `response` is the cached snapshot from last launch rather
    /// than a live one — used to show "Updated Xs ago" instead of implying
    /// this is current data before the first real fetch completes.
    @Published var lastUpdatedAt: Date?

    private let socket = SwarmLiveSocket.shared
    private let api = APIClient.shared
    private var pollTask: Task<Void, Never>?
    private var started = false

    private static let cacheKey = "swarmpanel.dashboardSnapshot"
    private static let cacheTimestampKey = "swarmpanel.dashboardSnapshotAt"

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode(DashboardResponse.self, from: data) else { return }
        response = cached
        lastUpdatedAt = UserDefaults.standard.object(forKey: Self.cacheTimestampKey) as? Date
    }

    func start() {
        guard !started else { return }
        started = true

        socket.watch("dashboard", as: DashboardResponse.self) { [weak self] result in
            guard let self, case .success(let snapshot) = result else { return }
            self.response = snapshot
            self.persistSnapshot(snapshot)
        }
        socket.connect()

        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.loadOnce()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                if !self.socket.isConnected {
                    await self.loadOnce(silent: true)
                }
            }
        }
    }

    func stop() {
        started = false
        pollTask?.cancel()
        pollTask = nil
        socket.unwatch("dashboard")
    }

    func refresh() async {
        await loadOnce()
    }

    /// Reuses the same leaderboard endpoint the Leaderboard tab calls —
    /// there's no separate "music intelligence" endpoint, so the Dashboard
    /// teaser just asks for the account's own guild's #1 track.
    func loadTopTrack(botKey: String, guildId: String) async {
        guard !botKey.isEmpty, !guildId.isEmpty else {
            topTrack = nil
            return
        }
        do {
            let envelope: LeaderboardEnvelope = try await api.get(
                "/api/guilds/\(guildId)/leaderboard",
                query: ["bot_key": botKey]
            )
            topTrack = envelope.data.topTracks?.first
        } catch {
            if !error.isCancellation { topTrack = nil }
        }
    }

    private func loadOnce(silent: Bool = false) async {
        if !silent { isLoading = true }
        do {
            let fresh: DashboardResponse = try await api.get("/api/dashboard")
            response = fresh
            errorMessage = nil
            persistSnapshot(fresh)
        } catch {
            if !silent, !error.isCancellation {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load dashboard."
            }
        }
        if !silent { isLoading = false }
    }

    private func persistSnapshot(_ snapshot: DashboardResponse) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let now = Date()
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
        UserDefaults.standard.set(now, forKey: Self.cacheTimestampKey)
        lastUpdatedAt = now
    }
}
