import Combine
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

    let socket = DashboardSocket()
    private let api = APIClient.shared
    private var pollTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
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

        socket.$snapshot
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.response = snapshot
                self?.persistSnapshot(snapshot)
            }
            .store(in: &cancellables)
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
        cancellables.removeAll()
        socket.disconnect()
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

    /// Bumped at the start of every loadOnce() call and captured locally so a
    /// slower, overlapping request (e.g. the 15s poll racing a manual
    /// pull-to-refresh) can never clobber a newer response with a stale one.
    private var loadGeneration = 0

    private func loadOnce(silent: Bool = false) async {
        if !silent { isLoading = true }
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let fresh: DashboardResponse = try await api.get("/api/dashboard")
            if generation == loadGeneration {
                response = fresh
                errorMessage = nil
                persistSnapshot(fresh)
            }
        } catch {
            if !silent, !error.isCancellation, generation == loadGeneration {
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
