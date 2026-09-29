import Combine
import Foundation
import UIKit

/// Client telemetry for the TV app. Events queue in memory, are mirrored to
/// UserDefaults so a batch survives the app being closed or killed, and
/// upload in batches to POST /api/telemetry/client (routes.lua) -- stored
/// server-side in swarmpanel_telemetry_events under category "client",
/// event names prefixed "tvos.".
///
/// Only operational data goes in here: event names, timings, counts, error
/// kinds and bot keys. Never tokens, passwords or message content -- the
/// server also drops credential-looking keys as a backstop.
@MainActor
final class TVTelemetry {
    static let shared = TVTelemetry()

    private struct Event: Codable {
        let name: String
        let at: Double
        var value: Double?
        var text: String?
        var metadata: [String: String]?
    }

    private struct Batch: Encodable {
        let client = "tvos"
        let appVersion: String
        let osVersion: String
        let deviceModel: String
        let launchId: String
        let events: [Event]
    }

    private static let queueKey = "swarmpanel.tv.telemetryQueue"
    private static let maxQueued = 300
    private static let batchSize = 50
    private static let flushInterval: TimeInterval = 60

    /// Random per launch, so one launch's events can be grouped server-side.
    let launchId = UUID().uuidString
    let launchedAt = Date()

    private var queue: [Event] = []
    private var flushing = false
    private var flushTask: Task<Void, Never>?
    private var socketObservation: AnyCancellable?
    private var socketConnectedAt: Date?
    private var socketDisconnects = 0

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.queueKey),
           let saved = try? JSONDecoder().decode([Event].self, from: data) {
            queue = saved
        }
    }

    /// Starts the periodic uploader and the live-socket connection tracker.
    /// Safe to call more than once.
    func start() {
        if flushTask == nil {
            flushTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.flushInterval))
                    if Task.isCancelled { break }
                    await self?.flush()
                }
            }
        }
        if socketObservation == nil {
            socketObservation = SwarmLiveSocket.shared.$isConnected
                .removeDuplicates()
                .dropFirst()
                .sink { [weak self] connected in
                    Task { @MainActor in self?.socketChanged(connected) }
                }
        }
    }

    func log(_ name: String, value: Double? = nil, text: String? = nil, _ metadata: [String: String] = [:]) {
        queue.append(Event(name: name, at: Date().timeIntervalSince1970, value: value, text: text,
                           metadata: metadata.isEmpty ? nil : metadata))
        if queue.count > Self.maxQueued { queue.removeFirst(queue.count - Self.maxQueued) }
        persist()
        if queue.count >= Self.batchSize { Task { await flush() } }
    }

    /// Milliseconds since `start`, for latency events.
    static func ms(since start: Date) -> Double {
        (Date().timeIntervalSince(start) * 1000).rounded()
    }

    /// Short, non-sensitive description of an error for the "kind" field.
    static func kind(of error: Error) -> String {
        if let api = error as? APIError {
            switch api {
            case .unauthorized: return "unauthorized"
            case .server(let status, _): return "server_\(status)"
            case .decoding: return "decoding"
            case .invalidResponse: return "invalid_response"
            case .network(let underlying):
                let ns = underlying as NSError
                return "network_\(ns.code)"
            }
        }
        if error is DecodingError { return "decoding" }
        let ns = error as NSError
        return "\(ns.domain)_\(ns.code)"
    }

    func flush() async {
        guard !flushing, !queue.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        let events = Array(queue.prefix(Self.batchSize))
        let batch = Batch(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            osVersion: UIDevice.current.systemVersion,
            deviceModel: Self.deviceModel,
            launchId: launchId,
            events: events
        )
        do {
            let _: OKResponse = try await APIClient.shared.post("/api/telemetry/client", body: batch)
            queue.removeFirst(min(events.count, queue.count))
            persist()
        } catch {
            // Keep the events for the next attempt (bounded by maxQueued).
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: Self.queueKey)
        }
    }

    private func socketChanged(_ connected: Bool) {
        if connected {
            socketConnectedAt = Date()
            log("socket_connected", ["disconnects_this_launch": String(socketDisconnects)])
        } else {
            socketDisconnects += 1
            let uptime = socketConnectedAt.map { Date().timeIntervalSince($0).rounded() }
            socketConnectedAt = nil
            log("socket_disconnected", value: uptime, ["disconnects_this_launch": String(socketDisconnects)])
        }
    }

    /// Hardware identifier like "AppleTV14,1" (tells an Apple TV 4K apart
    /// from an HD), rather than the generic UIDevice.model ("Apple TV").
    private static let deviceModel: String = {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        let id = mirror.children.reduce(into: "") { result, element in
            if let value = element.value as? Int8, value != 0 { result.append(Character(UnicodeScalar(UInt8(value)))) }
        }
        return id.isEmpty ? UIDevice.current.model : id
    }()
}
