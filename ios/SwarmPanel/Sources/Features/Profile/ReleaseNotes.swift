import Foundation

struct ReleaseNote: Identifiable {
    let version: String
    let highlights: [String]

    var id: String { version }
}

/// Static changelog shown on the "What's New" screen — updated by hand
/// alongside each ios/vX.Y.Z tag, mirroring the tag's own release notes.
let releaseNotes: [ReleaseNote] = [
    ReleaseNote(version: "0.6.0", highlights: [
        "Drag-to-seek scrubbing on the Now Playing progress bar",
        "\"Queue This\" to replay an upcoming track instantly from Bot Detail",
        "Loop and filter mode quick-set directly from Bot Detail",
        "Pin favorite bots to a permanent section on Dashboard",
        "Share fleet status, a bot's Up Next queue, or the Top Track teaser",
        "Dashboard now shows cached data instantly on relaunch while refreshing",
        "Confirmation prompts before destructive actions like deleting a queue or account",
    ]),
    ReleaseNote(version: "0.5.0", highlights: [
        "Now Playing visualization: thumbnail artwork, live progress bar, media-source badges",
        "Applies to Dashboard's quick control, every Live Sessions row, and Bot Detail",
    ]),
    ReleaseNote(version: "0.4.0", highlights: [
        "Toast confirmations for copy/save/delete actions",
        "Optional Face ID / Touch ID app lock",
        "Home Screen quick actions and swarmpanel:// deep links",
        "Tap or copy video links from Leaderboard and Bot Detail",
        "Leaderboard sort toggle, Dashboard session quick actions, Recently Viewed bots",
        "Share actions for Top Track and Fleet Health, Notifications search, pull-to-refresh haptics",
    ]),
    ReleaseNote(version: "0.3.0", highlights: [
        "Haptic feedback across key actions and a notification badge on the app icon",
        "Bot detail drill-down from Dashboard sessions",
        "Skeleton loading placeholders, swipe actions across lists",
        "Alternate app icons (Light, Neon)",
    ]),
    ReleaseNote(version: "0.2.0", highlights: [
        "Visual redesign matching the web panel's dark theme and accent color",
    ]),
    ReleaseNote(version: "0.1.0", highlights: [
        "First release: Dashboard, Controls, Leaderboard, Notifications, Social, and Profile",
    ]),
]
