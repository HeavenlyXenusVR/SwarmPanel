import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

@available(iOS 16.1, *)
private func liveActivityFormatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}

@available(iOS 16.1, *)
private func liveActivityThumbnail() -> UIImage? {
    guard let ud = UserDefaults(suiteName: WidgetShared.appGroupID),
          let relPath = ud.string(forKey: WidgetShared.Keys.thumbnailPath),
          let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetShared.appGroupID)
    else { return nil }
    return UIImage(contentsOfFile: container.appendingPathComponent(relPath).path)
}

@available(iOS 16.1, *)
private struct LiveActivityThumbnailView: View {
    let image: UIImage?
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 8

    var body: some View {
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
                        .foregroundStyle(.white.opacity(0.7))
                        .font(.system(size: size * 0.4))
                )
        }
    }
}

@available(iOS 16.1, *)
private struct LiveActivityProgressBar: View {
    let state: SwarmPanelActivityAttributes.ContentState
    var tint: Color = .cyan

    var body: some View {
        GeometryReader { geo in
            let fraction = state.duration > 0 ? min(1, max(0, state.position / state.duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(tint)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
    }
}

@available(iOS 16.1, *)
private struct LiveActivityTransportControls: View {
    let state: SwarmPanelActivityAttributes.ContentState
    var iconSize: CGFloat = 20
    var spacing: CGFloat = 26

    var body: some View {
        if #available(iOS 17.0, *) {
            HStack(spacing: spacing) {
                if state.isPlaying && !state.isPaused {
                    Button(intent: PauseTrackIntent()) {
                        Image(systemName: "pause.fill")
                            .font(.system(size: iconSize, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(intent: ResumeTrackIntent()) {
                        Image(systemName: "play.fill")
                            .font(.system(size: iconSize, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }

                Button(intent: SkipTrackIntent()) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: iconSize * 0.85, weight: .medium))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
        } else {
            Image(systemName: state.isPlaying && !state.isPaused ? "pause.fill" : "play.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

/// Lock Screen banner + Dynamic Island presentation for the account's own
/// guild's Now Playing session. Content comes from
/// `SwarmPanelActivityAttributes.ContentState`, pushed locally by
/// `LiveActivityManager` in the host app; artwork is read straight off the
/// shared App Group container, same as `SwarmPanelWidgetProvider` does.
@available(iOS 16.1, *)
struct SwarmPanelLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SwarmPanelActivityAttributes.self) { context in
            // MARK: Lock Screen / banner
            let state = context.state
            let thumbnail = liveActivityThumbnail()
            HStack(spacing: 12) {
                LiveActivityThumbnailView(image: thumbnail, size: 50, cornerRadius: 10)

                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title.isEmpty ? "Nothing Playing" : state.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !state.subtitle.isEmpty {
                        Text(state.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }

                    if !state.title.isEmpty {
                        LiveActivityProgressBar(state: state)
                        HStack {
                            if state.isPlaying, state.duration > 0 {
                                Text(timerInterval: state.trackRange, countsDown: false, showsHours: false)
                                    .font(.system(size: 10))
                                    .monospacedDigit()
                                    .foregroundStyle(.white.opacity(0.7))
                            } else {
                                Text(liveActivityFormatTime(state.position))
                                    .font(.system(size: 10))
                                    .monospacedDigit()
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            Spacer()
                            Text(liveActivityFormatTime(state.duration))
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }

                Spacer(minLength: 0)

                LiveActivityTransportControls(state: state)
            }
            .padding(14)
            .activityBackgroundTint(Color.black)
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            let state = context.state
            let thumbnail = liveActivityThumbnail()

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveActivityThumbnailView(image: thumbnail, size: 40, cornerRadius: 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LiveActivityTransportControls(state: state, iconSize: 16, spacing: 16)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.title.isEmpty ? "Nothing Playing" : state.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if !state.subtitle.isEmpty {
                            Text(state.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                        if !state.title.isEmpty {
                            LiveActivityProgressBar(state: state)
                        }
                    }
                }
            } compactLeading: {
                LiveActivityThumbnailView(image: thumbnail, size: 20, cornerRadius: 4)
            } compactTrailing: {
                Image(systemName: state.isPlaying && !state.isPaused ? "waveform" : "pause.fill")
                    .foregroundStyle(.cyan)
                    .font(.system(size: 13, weight: .semibold))
            } minimal: {
                Image(systemName: state.isPlaying && !state.isPaused ? "waveform" : "pause.fill")
                    .foregroundStyle(.cyan)
            }
            .widgetURL(nil)
            .keylineTint(.cyan)
        }
    }
}
