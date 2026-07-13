import Foundation

/// Native port of frontend/src/hooks/useDashboardStream.js: connects to /ws,
/// sends {"type":"auth","token":...} as the first frame (no cookie needed),
/// listens for dashboard_snapshot / dashboard_snapshot_error / ping (replies
/// pong), and auto-reconnects with exponential backoff. Same protocol, same
/// message shapes — this is a direct port, not a new one.
@MainActor
final class DashboardSocket: ObservableObject {
    @Published private(set) var snapshot: DashboardResponse?
    @Published private(set) var isConnected = false

    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 1
    private var shouldStayConnected = false

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func connect() {
        shouldStayConnected = true
        guard task == nil, let token = APIClient.shared.token else { return }

        var components = URLComponents(url: APIClient.shared.baseURL, resolvingAgainstBaseURL: false)
        let isHTTPS = components?.scheme == "https"
        components?.scheme = isHTTPS ? "wss" : "ws"
        components?.path = "/ws"
        guard let url = components?.url else { return }

        let socketTask = URLSession.shared.webSocketTask(with: url)
        task = socketTask
        socketTask.resume()

        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await socketTask.send(.string(#"{"type":"auth","token":"\#(token)"}"#))
            } catch {
                await self.scheduleReconnect()
                return
            }
            await self.receiveLoop(socketTask)
        }
    }

    func disconnect() {
        shouldStayConnected = false
        receiveTask?.cancel()
        reconnectTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    private func receiveLoop(_ socketTask: URLSessionWebSocketTask) async {
        isConnected = true
        reconnectDelay = 1
        while !Task.isCancelled {
            do {
                let message = try await socketTask.receive()
                handle(message)
            } catch {
                isConnected = false
                await scheduleReconnect()
                return
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message, let data = text.data(using: .utf8) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }

        switch type {
        case "dashboard_snapshot":
            if let envelope = try? decoder.decode(SnapshotEnvelope.self, from: data) {
                snapshot = envelope.data
            }
        case "ping":
            let currentTask = task
            Task { try? await currentTask?.send(.string(#"{"type":"pong"}"#)) }
        default:
            break
        }
    }

    private func scheduleReconnect() async {
        task = nil
        isConnected = false
        guard shouldStayConnected else { return }
        reconnectTask?.cancel()
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }
}

private struct SnapshotEnvelope: Decodable {
    let type: String
    let data: DashboardResponse
}
