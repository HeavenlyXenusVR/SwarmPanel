import AppIntents

/// App Intents (iOS 16+) — unlike the old SiriKit extension model, these
/// don't need a separate extension target, entitlement, or Apple Developer
/// Program capability to register Siri phrases, which matters since this
/// app is signed with a free/personal-team Apple ID via AltStore, not a
/// paid account. `openAppWhenRun = false` on all of these so "Hey Siri,
/// skip the track" doesn't have to foreground the app first.

struct SkipTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Track"
    static var description = IntentDescription("Skips the current track on your guild's SwarmPanel bot.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = try await FleetControlService.send("SKIP")
        let title = session.title?.isEmpty == false ? session.title! : "the current track"
        return .result(dialog: "Skipped \(title).")
    }
}

struct PauseTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Bot"
    static var description = IntentDescription("Pauses your guild's SwarmPanel bot.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await FleetControlService.send("PAUSE")
        return .result(dialog: "Paused.")
    }
}

struct ResumeTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Bot"
    static var description = IntentDescription("Resumes playback on your guild's SwarmPanel bot.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await FleetControlService.send("RESUME")
        return .result(dialog: "Resumed.")
    }
}

struct WhatsPlayingIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Playing"
    static var description = IntentDescription("Reports what's currently playing on your guild's SwarmPanel bot.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (_, session) = try await FleetControlService.ownSession()
        guard session.isPlaying == true, let title = session.title, !title.isEmpty else {
            return .result(dialog: "Nothing is playing right now.")
        }
        return .result(dialog: "Now playing: \(title).")
    }
}

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
