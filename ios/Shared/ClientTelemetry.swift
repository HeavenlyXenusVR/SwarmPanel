import Combine
import Foundation
import UIKit

// Matches routes.lua's KNOWN_CLIENTS, and becomes the prefix on every event
// name server-side ("tvos.app_launch", "ios.app_launch"). File scope rather
// than a static on the @MainActor class below so the nested Batch's default
// initializer can read it without actor-isolation trouble.
#if os(tvOS)
private let swarmClientName = "tvos"
#else
private let swarmClientName = "ios"
#endif

/// Client telemetry for the native apps (iPhone and Apple TV). Events queue
/// in memory, are mirrored to UserDefaults so a batch survives the app being
/// closed or killed, and upload in batches to POST /api/telemetry/client
/// (routes.lua) -- stored server-side in swarmpanel_telemetry_events under
/// category "client", event names prefixed "ios." / "tvos.".
///
/// Only operational data goes in here: event names, timings, counts, error
/// kinds and bot keys. Never tokens, passwords or message content -- the
/// server also drops credential-looking keys as a backstop.
///
/// Shared by both app targets (see ios/project.yml). `TVTelemetry` is a
/// typealias onto this class, so the Apple TV call sites read unchanged.
@MainActor
final class ClientTelemetry {
    static let shared = ClientTelemetry()

    nonisolated static var clientName: String { swarmClientName }

    private struct Event: Codable {
        let name: String
        let at: Double
        var value: Double?
        var text: String?
        var metadata: [String: String]?
    }

    private struct Batch: Encodable {
        let client = swarmClientName
        let appVersion: String
        let osVersion: String
        let deviceModel: String
        let launchId: String
        let events: [Event]
    }

    private static let queueKey = "swarmpanel.client.telemetryQueue"
    /// Pre-existing tvOS queue key, drained once on first launch after the
    /// move to this shared class so an Apple TV mid-upgrade doesn't silently
    /// drop whatever it had already recorded.
    private static let legacyTVQueueKey = "swarmpanel.tv.telemetryQueue"
    private static let maxQueued = 300
    private static let batchSize = 50
    private static let flushInterval: TimeInterval = 60
    /// First upload after launch. A full `flushInterval` was far too long:
    /// an Apple TV app is routinely killed along with the TV well inside 60
    /// seconds, so the launch's events -- and any backlog persisted by
    /// earlier launches -- never got uploaded at all, which is why the
    /// server-side "client" telemetry could trail live use by days.
    private static let initialFlushDelay: TimeInterval = 5
    /// Batches per flush. maxQueued / batchSize, so one flush can clear a
    /// full queue, while staying under routes.lua's 10-batches-per-60s
    /// client-telemetry rate limit.
    private static let maxBatchesPerFlush = 6
    /// A flush left in-flight for longer than this is treated as abandoned
    /// rather than still running (see `flush()`).
    private static let flushWedgeTimeout: TimeInterval = 120

    /// Random per launch, so one launch's events can be grouped server-side.
    let launchId = UUID().uuidString
    let launchedAt = Date()

    private var queue: [Event] = []
    private var flushing = false
    private var flushStartedAt: Date?
    private var flushTask: Task<Void, Never>?
    private var socketObservation: AnyCancellable?
    private var socketConnectedAt: Date?
    private var socketDisconnects = 0

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.queueKey),
           let saved = try? JSONDecoder().decode([Event].self, from: data) {
            queue = saved
        }
        if let legacy = defaults.data(forKey: Self.legacyTVQueueKey) {
            if let saved = try? JSONDecoder().decode([Event].self, from: legacy) {
                queue.append(contentsOf: saved)
                trimQueue()
            }
            defaults.removeObject(forKey: Self.legacyTVQueueKey)
            persist()
        }
    }

    /// Starts the periodic uploader and the live-socket connection tracker.
    /// Safe to call more than once.
    func start() {
        if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.initialFlushDelay))
                if Task.isCancelled { return }
                await self?.flush()
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
        // The launch id is stamped per event here rather than being taken
        // from the live process at upload time: a persisted batch regularly
        // outlives the launch that produced it, and stamping at flush time
        // relabelled day-old events with the current launch -- which made
        // several distinct launches look like one long-running session.
        // routes.lua merges event metadata over the batch-level fields, so
        // this wins over Batch.launchId for events that carry it.
        var meta = metadata
        meta["launch_id"] = launchId
        queue.append(Event(name: name, at: Date().timeIntervalSince1970, value: value, text: text,
                           metadata: meta))
        trimQueue()
        persist()
        if queue.count >= Self.batchSize { Task { await flush() } }
    }

    private func trimQueue() {
        if queue.count > Self.maxQueued { queue.removeFirst(queue.count - Self.maxQueued) }
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
        // `flushing` used to be a plain re-entrancy guard, which could pin
        // itself true for the rest of the process: the flush kicked off as
        // the app is being suspended can be left suspended mid-`await` and
        // never resumed, so its `defer` never ran and every later flush
        // returned immediately. Treat an in-flight flush older than
        // flushWedgeTimeout as abandoned instead.
        if flushing {
            guard let started = flushStartedAt,
                  Date().timeIntervalSince(started) > Self.flushWedgeTimeout else { return }
        }
        guard !queue.isEmpty else { return }
        flushing = true
        flushStartedAt = Date()
        defer {
            flushing = false
            flushStartedAt = nil
        }

        // Drain the backlog rather than one batch per call: a device awake
        // for only a few seconds at a time otherwise never catches up, and
        // the queue just keeps ageing until it hits maxQueued and events
        // start falling off the front.
        var batches = 0
        while !queue.isEmpty, batches < Self.maxBatchesPerFlush {
            batches += 1
            let events = Array(queue.prefix(Self.batchSize))
            let batch = Batch(
                appVersion: Self.appVersion,
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
                return
            }
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

    private static let appVersion: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    /// Hardware identifier like "AppleTV14,1" (tells an Apple TV 4K apart
    /// from an HD) or "iPhone15,2", rather than the generic UIDevice.model
    /// ("Apple TV" / "iPhone").
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
