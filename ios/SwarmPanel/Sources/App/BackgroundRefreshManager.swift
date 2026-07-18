import BackgroundTasks
import UserNotifications

/// Best-effort background notification delivery — the workaround for not
/// having a paid Apple Developer Program account, which real APNs push
/// requires. iOS decides if/when a BGAppRefreshTask actually runs based on
/// usage patterns and battery, with no guaranteed schedule, and it does NOT
/// run at all once the user force-quits the app from the app switcher —
/// only while it's backgrounded (not killed) does this help. Foreground
/// polling (NotificationsViewModel, every 20s) stays the reliable path;
/// this only extends coverage a little further, into the background.
enum BackgroundRefreshManager {
    static let refreshTaskIdentifier = "com.swarmpanel.ios.refresh"
    private static let lastNotifiedIdKey = "swarmpanel.lastNotifiedNotificationId"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            handle(task: refreshTask)
        }
    }

    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(task: BGAppRefreshTask) {
        scheduleNext()
        let work = Task {
            await checkForNewNotifications()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    private static func checkForNewNotifications() async {
        guard APIClient.shared.token != nil else { return }
        do {
            let response: NotificationsResponse = try await APIClient.shared.get("/api/notifications")
            let unread = (response.notifications ?? []).filter { $0.isUnread }
            let lastNotifiedId = UserDefaults.standard.integer(forKey: lastNotifiedIdKey)
            let fresh = unread.filter { $0.id > lastNotifiedId }.sorted { $0.id < $1.id }
            guard !fresh.isEmpty else { return }
            // Cap how many banners a single background run can fire — a long
            // stretch away from the app shouldn't dump a wall of notifications.
            for notification in fresh.suffix(5) {
                await deliver(notification)
            }
            if let maxId = unread.map(\.id).max() {
                UserDefaults.standard.set(maxId, forKey: lastNotifiedIdKey)
            }
        } catch {
            // Best-effort — the next scheduled run (or the next foreground poll) reconciles.
        }
    }

    private static func deliver(_ notification: PanelNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        if let body = notification.body, !body.isEmpty { content.body = body }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "swarmpanel.notification.\(notification.id)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
