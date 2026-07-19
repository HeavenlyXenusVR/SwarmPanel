import Foundation

struct ReleaseNote: Identifiable {
    let version: String
    let highlights: [String]

    var id: String { version }
}

/// CFBundleShortVersionString, e.g. "0.7.3" — matches the `ios/vX.Y.Z` tag
/// format (with the "v" stripped) that release-ios.yml stamps into
/// MARKETING_VERSION, which is in turn what `releaseNotes` entries below are
/// keyed by.
let currentAppVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

/// Static changelog shown on the "What's New" screen — updated by hand
/// alongside each ios/vX.Y.Z tag, mirroring the tag's own release notes.
let releaseNotes: [ReleaseNote] = [
    ReleaseNote(version: "0.9.0", highlights: [
        "New \"Reset Queue\" control action: clears a guild bot's live queue and backup queue while leaving it connected and playing, so it repopulates itself instead of stopping",
        "Live data now refreshes automatically when the app returns to the foreground, including Profile's Admin Tools visibility, which used to need a relaunch to catch a role change",
        "Message threads now poll for new messages and support pull-to-refresh",
        "New Invite Bots and Swarm Directory screens (Profile), a new Database Viewer (Admin Tools), and a live Events feed on Fleet Health — closing the remaining gaps with the web dashboard",
    ]),
    ReleaseNote(version: "0.8.0", highlights: [
        "Home Screen & Lock Screen widgets: fleet status (bots/live/queued) and your guild's Now Playing track",
        "Live Activity for your guild's Now Playing session on the Lock Screen and Dynamic Island, with Skip/Pause/Resume buttons",
    ]),
    ReleaseNote(version: "0.7.5", highlights: [
        "Siri & Shortcuts support: \"Skip the track\", \"Pause\", \"Resume\", and \"What's playing\" for your guild's bot",
        "Notifications can now arrive in the background as local banners (best-effort — this app isn't on a paid Apple Developer account, so this isn't true push, just an opportunistic background check)",
    ]),
    ReleaseNote(version: "0.7.4", highlights: [
        "New Fleet Topology screen (Admin Tools): see which bot is serving which guild, flags any guild covered by more than one bot, and lets admins restart a bot from the list",
        "What's New now surfaces automatically after an update instead of only being reachable from Profile",
        "Alert Rules' empty state now jumps straight to the New Rule form",
    ]),
    ReleaseNote(version: "0.7.3", highlights: [
        "Fixed a crash when tapping bots or cards on Dashboard",
    ]),
    ReleaseNote(version: "0.7.2", highlights: [
        "Refined-native visual treatment extended to Admin, Login, Register, and Server Settings",
    ]),
    ReleaseNote(version: "0.7.1", highlights: [
        "Refined-native visual treatment extended to Controls, Leaderboard, Social, and Notifications",
    ]),
    ReleaseNote(version: "0.7.0", highlights: [
        "New \"refined native iOS\" visual direction: colored icon chips, card shadows, live-pulsing status dots",
        "Applied to Dashboard, Bot Detail, and Profile",
    ]),
    ReleaseNote(version: "0.6.3", highlights: [
        "Reworked the Now Playing progress bar to keep its drag-to-seek gesture stable during live updates",
    ]),
    ReleaseNote(version: "0.6.2", highlights: [
        "Fixed alternate app icons (Light, Neon) not applying",
    ]),
    ReleaseNote(version: "0.6.1", highlights: [
        "Fixed control actions failing to send from Controls",
    ]),
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
