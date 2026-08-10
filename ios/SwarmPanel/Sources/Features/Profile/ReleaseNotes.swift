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
    ReleaseNote(version: "0.12.2", highlights: [
        "Controls now shows real Discord guild names instead of bare IDs, matching the web panel",
    ]),
    ReleaseNote(version: "0.12.1", highlights: [
        "Profile now has an Admin Mode toggle for owner accounts, matching the web panel's topbar switch",
    ]),
    ReleaseNote(version: "0.12.0", highlights: [
        "Registration now offers Discord DM verification as an alternative to the server-webhook proof -- enter your Discord User ID and get a code sent straight to your DMs",
    ]),
    ReleaseNote(version: "0.11.6", highlights: [
        "Controls now shows a plain-language preview of exactly what Send Control will do before you send it",
    ]),
    ReleaseNote(version: "0.11.5", highlights: [
        "Accounts admin now shows a verified/unverified/moderator summary above the list, matching the web panel",
    ]),
    ReleaseNote(version: "0.11.4", highlights: [
        "Alert Rules: the New Rule form can now set an escalation window and email escalation directly, instead of only being settable from the web panel",
    ]),
    ReleaseNote(version: "0.11.3", highlights: [
        "Fixed \"Couldn't read the server's response\" on Swarm Directory and the Friends list for any account with a guild -- a guild ID field was typed as a number instead of text, and Discord's real guild IDs are too large for that to ever work",
    ]),
    ReleaseNote(version: "0.11.2", highlights: [
        "Database Viewer: id/hash/token-shaped columns are now shown in a monospaced, accent-tinted style so they read as identifiers at a glance",
    ]),
    ReleaseNote(version: "0.11.1", highlights: [
        "Audit Log entries now show a readable before -> after diff for each changed field instead of a raw JSON blob",
    ]),
    ReleaseNote(version: "0.11.0", highlights: [
        "Fleet Topology: \"Recover All\" sends RECOVER to every bot/guild session currently pending recovery in one tap, instead of one at a time",
        "Gallery Moderation: select multiple comments and delete them in one action",
    ]),
    ReleaseNote(version: "0.10.1", highlights: [
        "Fixed Dashboard (the app's first tab) doing a full reconnect and re-fetch every time you switched away to another tab and back — it was tearing down a perfectly good live connection on ordinary navigation, not just when the app actually backgrounded, which made the app feel like it took forever to reload",
    ]),
    ReleaseNote(version: "0.10.0", highlights: [
        "New Swarm-Wide Leaderboard (admin): a scope toggle on Leaderboard shows top tracks across every bot's own database instead of one guild at a time",
        "Accounts admin: bulk select to verify/unverify or delete multiple accounts at once, plus Resend Verification for a single account",
        "Audit Log entries can now be reverted directly (where the server supports it), not just viewed",
        "Database Viewer: Truncate Table and Truncate Schema, gated behind the same double-confirmation the web panel requires",
        "New \"Swarm Pulse\" visual direction: a duotone accent gradient, pulsing live-status rings, and a hero-card treatment — starting on Dashboard's fleet summary",
        "Profile's admin tools moved from the bottom of a long scroll to a \"Command Center\" section right at the top",
    ]),
    ReleaseNote(version: "0.9.2", highlights: [
        "Fixed \"Missing trusted browser origin\" sometimes blocking logging back in after logging out, and fixed data not loading afterward — caused by a leftover cookie the app never actually needed",
    ]),
    ReleaseNote(version: "0.9.1", highlights: [
        "Fixed a bug from 0.9.0 where the Dashboard (and other screens) could get permanently stuck on stale data with no error shown, if the network was ever slow enough for two refreshes to overlap",
    ]),
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
