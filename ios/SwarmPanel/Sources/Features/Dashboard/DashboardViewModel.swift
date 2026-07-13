import Combine
import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var response: DashboardResponse?
    @Published var isLoading = true
    @Published var errorMessage: String?

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
