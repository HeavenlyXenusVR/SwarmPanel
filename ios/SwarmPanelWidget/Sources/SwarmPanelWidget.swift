import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Helpers

/// Applies containerBackground on iOS 17+; no-op on iOS 16.
struct WidgetBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.containerBackground(.black, for: .widget)
        } else {
            content
        }
    }
}

private func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - Timeline Entry

struct SwarmPanelEntry: TimelineEntry {
    let date: Date
    let title: String
    let subtitle: String
    let isPlaying: Bool
    let isPaused: Bool
    let thumbnail: UIImage?
    let position: TimeInterval
    let duration: TimeInterval
    /// The moment `position`/`isPlaying` were captured — feeds
    /// `Text(timerInterval:)` for a live-updating elapsed time without
    /// further widget reloads.
    let anchorDate: Date
    let botsCount: Int
    let liveCount: Int
    let queuedCount: Int

    var trackRange: ClosedRange<Date> {
        let start = anchorDate.addingTimeInterval(-position)
        let end = start.addingTimeInterval(max(duration, position))
        return start...max(start, end)
    }
}

// MARK: - Timeline Provider

struct SwarmPanelWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> SwarmPanelEntry {
        SwarmPanelEntry(
            date: Date(), title: "Nothing playing", subtitle: "", isPlaying: false, isPaused: false,
            thumbnail: nil, position: 0, duration: 0, anchorDate: Date(),
            botsCount: 0, liveCount: 0, queuedCount: 0
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SwarmPanelEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SwarmPanelEntry>) -> Void) {
        // .never: the main app drives all updates via WidgetCenter.reloadAllTimelines()
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> SwarmPanelEntry {
        let ud = UserDefaults(suiteName: WidgetShared.appGroupID)
        let title = ud?.string(forKey: WidgetShared.Keys.title) ?? ""
        let subtitle = ud?.string(forKey: WidgetShared.Keys.subtitle) ?? ""
        let isPlaying = ud?.bool(forKey: WidgetShared.Keys.isPlaying) ?? false
        let isPaused = ud?.bool(forKey: WidgetShared.Keys.isPaused) ?? false
        let position = ud?.double(forKey: WidgetShared.Keys.position) ?? 0
        let duration = ud?.double(forKey: WidgetShared.Keys.duration) ?? 0
        let anchor = ud?.double(forKey: WidgetShared.Keys.anchorDate)
        let anchorDate = anchor.map { Date(timeIntervalSinceReferenceDate: $0) } ?? Date()

        var thumbnail: UIImage?
        if let relPath = ud?.string(forKey: WidgetShared.Keys.thumbnailPath),
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetShared.appGroupID) {
            thumbnail = UIImage(contentsOfFile: container.appendingPathComponent(relPath).path)
        }

        return SwarmPanelEntry(
            date: Date(), title: title, subtitle: subtitle, isPlaying: isPlaying, isPaused: isPaused,
            thumbnail: thumbnail, position: position, duration: duration, anchorDate: anchorDate,
            botsCount: ud?.integer(forKey: WidgetShared.Keys.botsCount) ?? 0,
            liveCount: ud?.integer(forKey: WidgetShared.Keys.liveCount) ?? 0,
            queuedCount: ud?.integer(forKey: WidgetShared.Keys.queuedCount) ?? 0
        )
    }
}

// MARK: - Shared progress bar / time label

struct WidgetProgressBar: View {
    let entry: SwarmPanelEntry
    var tint: Color = .white

    var body: some View {
        GeometryReader { geo in
            let fraction = entry.duration > 0 ? min(1, max(0, entry.position / entry.duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(tint)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
    }
}

struct WidgetTimeLabel: View {
    let entry: SwarmPanelEntry
    var font: Font = .system(size: 10)

    var body: some View {
        if entry.isPlaying, entry.duration > 0 {
            Text(timerInterval: entry.trackRange, countsDown: false, showsHours: false)
                .font(font)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
        } else {
            Text(formatTime(entry.position))
                .font(font)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}

@ViewBuilder
private func thumbnailView(_ image: UIImage?, size: CGFloat, cornerRadius: CGFloat) -> some View {
    if let image {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    } else {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.gray.opacity(0.35))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "music.note")
                    .foregroundStyle(.white.opacity(0.6))
                    .font(.system(size: size * 0.4))
            )
    }
}

// MARK: - Small Widget View (fleet status)

struct WidgetFleetStatusView: View {
    let entry: SwarmPanelEntry

    var body: some View {
        ZStack {
            Color.black
            VStack(alignment: .leading, spacing: 10) {
                Label("SwarmPanel", systemImage: "server.rack")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                stat(value: entry.botsCount, label: "Bots", color: .blue)
                stat(value: entry.liveCount, label: "Live", color: .green)
                stat(value: entry.queuedCount, label: "Queued", color: .purple)
            }
            .padding(12)
        }
    }

    private func stat(value: Int, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(value)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

// MARK: - Medium Widget View (now playing)

struct WidgetNowPlayingView: View {
    let entry: SwarmPanelEntry

    var body: some View {
        ZStack {
            Color.black
            HStack(spacing: 14) {
                thumbnailView(entry.thumbnail, size: 70, cornerRadius: 10)

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title.isEmpty ? "Nothing Playing" : entry.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if !entry.subtitle.isEmpty {
                        Text(entry.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    if !entry.title.isEmpty {
                        WidgetProgressBar(entry: entry)
                        HStack {
                            WidgetTimeLabel(entry: entry)
                            Spacer()
                            Text(formatTime(entry.duration))
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }

                    Spacer(minLength: 4)

                    if #available(iOS 17.0, *) {
                        HStack(spacing: 20) {
                            Button(intent: entry.isPlaying && !entry.isPaused ? PauseTrackIntent() : ResumeTrackIntent()) {
                                Image(systemName: entry.isPlaying && !entry.isPaused ? "pause.fill" : "play.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)

                            Button(intent: SkipTrackIntent()) {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }
}

// MARK: - Lock Screen accessory views

struct WidgetCircularView: View {
    let entry: SwarmPanelEntry

    var body: some View {
        ZStack {
            thumbnailView(entry.thumbnail, size: 50, cornerRadius: 25)
                .clipShape(Circle())
                .overlay(Circle().stroke(entry.isPlaying ? Color.cyan : Color.white.opacity(0.3), lineWidth: 2))
        }
        .widgetLabel {
            Text(entry.title.isEmpty ? "Idle" : entry.title)
                .lineLimit(1)
        }
    }
}

struct WidgetRectangularView: View {
    let entry: SwarmPanelEntry

    var body: some View {
        HStack(spacing: 8) {
            thumbnailView(entry.thumbnail, size: 36, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? "Nothing Playing" : entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(entry.subtitle)
                    .font(.system(size: 11))
                    .opacity(0.7)
                    .lineLimit(1)
                if !entry.title.isEmpty {
                    WidgetProgressBar(entry: entry, tint: .cyan)
                }
            }
        }
    }
}

struct WidgetInlineView: View {
    let entry: SwarmPanelEntry

    var body: some View {
        if entry.title.isEmpty {
            Text("SwarmPanel: \(entry.liveCount) live")
        } else {
            Text("\(entry.isPlaying && !entry.isPaused ? "▶" : "⏸") \(entry.title)")
        }
    }
}

// MARK: - Entry View (dispatches to family-specific view)

struct SwarmPanelWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SwarmPanelEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            WidgetCircularView(entry: entry)
        case .accessoryRectangular:
            WidgetRectangularView(entry: entry)
        case .accessoryInline:
            WidgetInlineView(entry: entry)
        case .systemMedium:
            WidgetNowPlayingView(entry: entry)
        default:
            WidgetFleetStatusView(entry: entry)
        }
    }
}

// MARK: - Widget Configuration

struct SwarmPanelWidget: Widget {
    let kind = "SwarmPanelWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SwarmPanelWidgetProvider()) { entry in
            SwarmPanelWidgetEntryView(entry: entry)
                .modifier(WidgetBackgroundModifier())
        }
        .configurationDisplayName("SwarmPanel")
        .description("Fleet status and your guild's Now Playing track.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

// MARK: - Widget Bundle Entry Point

@main
struct SwarmPanelWidgetBundle: WidgetBundle {
    var body: some Widget {
        SwarmPanelWidget()
        if #available(iOS 16.1, *) {
            SwarmPanelLiveActivity()
        }
    }
}
