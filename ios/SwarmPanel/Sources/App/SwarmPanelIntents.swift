import AppIntents

/// Registers the Shared/SwarmPanelControlIntents.swift intents as Siri
/// phrases + Shortcuts app entries. App-target only — AppShortcutsProvider
/// belongs in the main app per Apple's guidance, not an extension, unlike
/// the intents themselves which SwarmPanelWidget's buttons also use.
struct SwarmPanelShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SkipTrackIntent(),
            phrases: [
                "Skip the track in \(.applicationName)",
                "Skip the song on \(.applicationName)",
            ],
            shortTitle: "Skip Track",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: PauseTrackIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Pause the bot in \(.applicationName)",
            ],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumeTrackIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Resume the bot in \(.applicationName)",
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: WhatsPlayingIntent(),
            phrases: [
                "What's playing on \(.applicationName)",
                "Ask \(.applicationName) what's playing",
            ],
            shortTitle: "What's Playing",
            systemImageName: "music.note"
        )
    }
}
