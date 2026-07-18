import Foundation
import UIKit
import WidgetKit

/// Writes the account's own-guild Now Playing state + fleet totals to the
/// shared App Group so SwarmPanelWidget can read them, then triggers a
/// widget timeline reload. Called from DashboardView whenever
/// DashboardViewModel's response updates.
@MainActor
final class WidgetDataService {
    static let shared = WidgetDataService()

    private var defaults: UserDefaults? { UserDefaults(suiteName: WidgetShared.appGroupID) }
    private var lastReloadTime: Date = .distantPast
    private var lastThumbnailURL: String?

    private init() {}

    /// Unlike `UserDefaults(suiteName:)` (which returns a usable but
    /// sandbox-local object even without the entitlement), this reliably
    /// returns `nil` when the App Group isn't actually provisioned for this
    /// build — most relevant on a sideloaded build whose resigning
    /// certificate/provisioning profile doesn't include the App Group.
    var isAppGroupAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetShared.appGroupID) != nil
    }

    func update(bots: [DashboardBot], ownSession: DashboardSession?) {
        guard let ud = defaults else { return }

        let sessions = bots.flatMap { $0.sessions ?? [] }
        ud.set(bots.count, forKey: WidgetShared.Keys.botsCount)
        ud.set(sessions.filter { $0.isPlaying == true }.count, forKey: WidgetShared.Keys.liveCount)
        ud.set(sessions.reduce(0) { $0 + ($1.queueCount ?? 0) }, forKey: WidgetShared.Keys.queuedCount)

        let title = ownSession?.title ?? ""
        let subtitle = ownSession?.channelName ?? ownSession?.guildName ?? ""
        let isPlaying = ownSession?.isPlaying ?? false
        let isPaused = ownSession?.isPaused ?? false
        let position = Double(ownSession?.positionSeconds ?? 0)
        let duration = Double(ownSession?.durationSeconds ?? 0)
        ud.set(title, forKey: WidgetShared.Keys.title)
        ud.set(subtitle, forKey: WidgetShared.Keys.subtitle)
        ud.set(isPlaying, forKey: WidgetShared.Keys.isPlaying)
        ud.set(isPaused, forKey: WidgetShared.Keys.isPaused)
        ud.set(position, forKey: WidgetShared.Keys.position)
        ud.set(duration, forKey: WidgetShared.Keys.duration)
        ud.set(Date().timeIntervalSinceReferenceDate, forKey: WidgetShared.Keys.anchorDate)

        reloadTimelinesThrottled()

        if #available(iOS 16.1, *) {
            LiveActivityManager.update(
                title: title, subtitle: subtitle, isPlaying: isPlaying, isPaused: isPaused,
                position: position, duration: duration
            )
        }

        Task { await downloadThumbnailIfNeeded(ownSession?.thumbnail) }
    }

    private func downloadThumbnailIfNeeded(_ urlString: String?) async {
        guard let urlString, !urlString.isEmpty else {
            clearThumbnail()
            return
        }
        guard urlString != lastThumbnailURL, let url = URL(string: urlString) else { return }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetShared.appGroupID) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data), let resized = Self.widgetSizedJPEG(image) else { return }
            let path = container.appendingPathComponent(WidgetShared.thumbnailFilename)
            try resized.write(to: path, options: .atomic)
            defaults?.set(WidgetShared.thumbnailFilename, forKey: WidgetShared.Keys.thumbnailPath)
            lastThumbnailURL = urlString
            reloadTimelinesThrottled()
        } catch {
            // Best-effort — the widget just shows a placeholder icon instead.
        }
    }

    private func clearThumbnail() {
        guard lastThumbnailURL != nil else { return }
        defaults?.removeObject(forKey: WidgetShared.Keys.thumbnailPath)
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetShared.appGroupID) {
            try? FileManager.default.removeItem(at: container.appendingPathComponent(WidgetShared.thumbnailFilename))
        }
        lastThumbnailURL = nil
    }

    /// Widget extensions run under a tight memory cap and decode this file
    /// with `UIImage(contentsOfFile:)` directly — handing them a full-size
    /// YouTube thumbnail risks the widget process getting killed mid-render.
    private static func widgetSizedJPEG(_ image: UIImage, maxPixelSize: CGFloat = 300) -> Data? {
        let scale = min(1, maxPixelSize / max(image.size.width, image.size.height))
        guard scale < 1 else { return image.jpegData(compressionQuality: 0.85) }
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: 0.85)
    }

    /// Calls `WidgetCenter.shared.reloadAllTimelines()` at most once every 2
    /// seconds — avoids redundant WidgetKit refreshes when several fields
    /// change in quick succession (e.g. a fresh dashboard snapshot).
    private func reloadTimelinesThrottled() {
        guard Date().timeIntervalSince(lastReloadTime) >= 2.0 else { return }
        lastReloadTime = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
