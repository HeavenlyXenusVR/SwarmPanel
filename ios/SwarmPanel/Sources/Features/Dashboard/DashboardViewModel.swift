import Combine
import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var response: DashboardResponse?
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var topTrack: LeaderboardTrack?

    let socket = DashboardSocket()
    private let api = APIClient.shared
    private var pollTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        socket.$snapshot
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in self?.response = snapshot }
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

    private func loadOnce(silent: Bool = false) async {
        if !silent { isLoading = true }
        do {
            response = try await api.get("/api/dashboard")
            errorMessage = nil
        } catch {
            if !silent, !error.isCancellation {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load dashboard."
            }
        }
        if !silent { isLoading = false }
    }
}
