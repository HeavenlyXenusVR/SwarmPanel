import Foundation
import UserNotifications

/// Owned once by RootTabView so the unread badge stays live regardless of
/// which tab is currently selected — mirrors the web bell's always-polling
/// behavior (frontend/src/components/Shell.jsx's NotificationsBell).
@MainActor
final class NotificationsViewModel: ObservableObject {
    @Published var notifications: [PanelNotification] = []
    @Published var unreadCount = 0 {
        didSet { updateAppIconBadge() }
    }
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let api = APIClient.shared
    private var pollTask: Task<Void, Never>?

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshUnreadCount()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if Task.isCancelled { break }
                await self.refreshUnreadCount()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshUnreadCount() async {
        do {
            let response: UnreadCountResponse = try await api.get("/api/notifications/unread-count")
            unreadCount = response.unreadCount ?? 0
        } catch {
            // Silent — notifications are non-critical, don't surface a toast for a failed poll.
        }
    }

    func loadNotifications() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: NotificationsResponse = try await api.get("/api/notifications")
            notifications = response.notifications ?? []
            errorMessage = nil
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load notifications."
        }
    }

    func markRead(_ notification: PanelNotification) async {
        guard notification.isUnread else { return }
        do {
            let _: OKResponse = try await api.post("/api/notifications/\(notification.id)/read")
            unreadCount = max(0, unreadCount - 1)
            if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
                notifications[index] = PanelNotification(
                    id: notification.id, kind: notification.kind, title: notification.title,
                    body: notification.body, linkPath: notification.linkPath,
                    readAt: "1970-01-01T00:00:00Z", createdAt: notification.createdAt
                )
            }
        } catch {
            // Best-effort — next poll/reload reconciles state.
        }
    }

    func markAllRead() async {
        do {
            let _: OKResponse = try await api.post("/api/notifications/read-all")
            unreadCount = 0
            await loadNotifications()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to mark all read."
        }
    }

    /// Best-effort — if badge authorization was never granted (or the user
    /// declined it), this just silently doesn't update the home screen badge;
    /// it never affects in-app behavior either way.
    private func updateAppIconBadge() {
        let count = unreadCount
        Task {
            try? await UNUserNotificationCenter.current().setBadgeCount(count)
        }
    }
}
