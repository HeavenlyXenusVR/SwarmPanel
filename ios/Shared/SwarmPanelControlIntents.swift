import AppIntents

/// App Intents (iOS 16+) — unlike the old SiriKit extension model, these
/// don't need a separate extension target, entitlement, or Apple Developer
/// Program capability to register, which matters since this app is signed
/// with a free/personal-team Apple ID via AltStore, not a paid account.
/// `openAppWhenRun = false` on all of these so "Hey Siri, skip the track"
/// (or tapping a widget button) doesn't have to foreground the app first.
///
/// Shared between the SwarmPanel app target and the SwarmPanelWidget
/// extension target (both list this file in project.yml) — unlike
/// Lumisound's widget intents, these don't need a Darwin-notification relay
/// to a possibly-suspended host app, since a SwarmPanel control action is
/// just a network POST (FleetControlService), not a local audio engine call
/// that only the host app process can make.

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
