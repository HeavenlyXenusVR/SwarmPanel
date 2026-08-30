import Foundation

/// Native port of static/app.js's swarmLiveConnect()/window.swarmLive: one
/// shared /ws connection for the whole app, multiplexed by "watch" key
/// (dashboard, control_state, notifications, thread_messages, ...) exactly
/// like the web panel. Sends {"type":"auth","token":...} as the first frame,
/// then {"type":"watch"/"unwatch","key":...,"params":...} per subscription;
/// receives {"type":"snapshot"/"snapshot_error","key":...,"data"/"error":...}
/// and dispatches to the one handler registered for that key (last watcher
/// wins per key — mirrors app.js's `handlers[key] = handler`, which exists
/// specifically to avoid duplicate-handler accumulation when a screen
/// resubscribes with new params, e.g. Controls switching bots).
@MainActor
final class SwarmLiveSocket: ObservableObject {
    static let shared = SwarmLiveSocket()

    @Published private(set) var isConnected = false

    private struct Watch {
        var params: [String: String]?
        var handler: (SnapshotResult) -> Void
    }

    enum SnapshotResult {
        case snapshot(Data)
        case error(String)
    }

    private var watches: [String: Watch] = [:]
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 1
    private var shouldStayConnected = false

    private init() {}

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
            // Replay every currently-registered watch onto the fresh
            // connection -- a brand-new socket only auto-subscribes
            // "dashboard" server-side, so anything else the app had
            // watched before a drop/reconnect needs to be resent.
            await self.resendAllWatches()
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

    /// Registers (or replaces) the handler for `key` and sends a "watch"
    /// frame. Safe to call before `connect()`/before the socket is up --
    /// the watch is queued and gets sent on the next successful connect via
    /// resendAllWatches(), same as a reconnect replay.
    func watch(_ key: String, params: [String: String]? = nil, handler: @escaping (SnapshotResult) -> Void) {
        watches[key] = Watch(params: params, handler: handler)
        sendWatch(key: key, params: params)
    }

    /// Re-sends a "watch" for an already-registered key with new params --
    /// e.g. Controls switching bot_key/guild_id. No-op if `key` was never
    /// watch()'d (mirrors app.js's resubscribe()).
    func resubscribe(_ key: String, params: [String: String]? = nil) {
        guard var existing = watches[key] else { return }
        existing.params = params
        watches[key] = existing
        sendWatch(key: key, params: params)
    }

    func unwatch(_ key: String) {
        guard watches[key] != nil else { return }
        watches.removeValue(forKey: key)
        send(#"{"type":"unwatch","key":"\#(jsonEscape(key))"}"#)
    }

    private func sendWatch(key: String, params: [String: String]?) {
        var json: [String: Any] = ["type": "watch", "key": key]
        if let params { json["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        send(text)
    }

    private func resendAllWatches() async {
        for (key, watch) in watches {
            sendWatch(key: key, params: watch.params)
        }
    }

    private func send(_ text: String) {
        guard let task else { return }
        Task { try? await task.send(.string(text)) }
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
        case "snapshot":
            guard let key = object["key"] as? String, let watch = watches[key] else { return }
            guard let payload = object["data"],
                  let payloadData = try? JSONSerialization.data(withJSONObject: payload) else { return }
            watch.handler(.snapshot(payloadData))
        case "snapshot_error":
            guard let key = object["key"] as? String, let watch = watches[key] else { return }
            watch.handler(.error(object["error"] as? String ?? "Unknown error"))
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

    private func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

extension SwarmLiveSocket {
    /// Convenience for the common case: decode the snapshot payload as `T`
    /// and hand back a `Result`, matching most ViewModels' existing
    /// do/catch-around-a-typed-response shape.
    func watch<T: Decodable>(
        _ key: String,
        params: [String: String]? = nil,
        as type: T.Type,
        decoder: JSONDecoder = SwarmLiveSocket.defaultDecoder,
        onUpdate: @escaping (Result<T, Error>) -> Void
    ) {
        watch(key, params: params) { result in
            switch result {
            case .snapshot(let data):
                do {
                    let decoded = try decoder.decode(T.self, from: data)
                    onUpdate(.success(decoded))
                } catch {
                    onUpdate(.failure(error))
                }
            case .error(let message):
                onUpdate(.failure(SwarmLiveError.snapshotError(message)))
            }
        }
    }

    static let defaultDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

enum SwarmLiveError: LocalizedError {
    case snapshotError(String)
    var errorDescription: String? {
        switch self {
        case .snapshotError(let message): return message
        }
    }
}
