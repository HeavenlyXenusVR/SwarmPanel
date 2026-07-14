import SwiftUI

/// Parses the naive (no Z/offset) UTC timestamps this backend emits via
/// Python's datetime.isoformat() — see MetricTrendChart.swift for the same
/// caveat. Used here to extrapolate playback position between snapshots.
private enum NaiveUTCDate {
    private static let withFraction: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return formatter
    }()

    private static let withoutFraction: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return withFraction.date(from: string) ?? withoutFraction.date(from: string)
    }
}

private func formatDuration(_ seconds: Int) -> String {
    guard seconds >= 0 else { return "0:00" }
    let minutes = seconds / 60
    let remainder = seconds % 60
    return String(format: "%d:%02d", minutes, remainder)
}

/// "Now Playing" visualization — thumbnail, title/subtitle, a live-ticking
/// progress bar (extrapolated client-side from the last known position +
/// its observed-at timestamp, since the server only snapshots periodically),
/// a media-source badge, and optional quick-action buttons. Used interactively
/// on Dashboard and read-only in BotDetailView.
struct NowPlayingCard: View {
    let title: String
    let subtitle: String?
    var thumbnailURL: String?
    var isPlaying: Bool
    var isPaused: Bool
    var positionSeconds: Int
    var durationSeconds: Int
    var positionObservedAt: String?
    var mediaSourceLabel: String?
    var cached: Bool?
    var isBusy: Bool = false
    var onPause: (() -> Void)? = nil
    var onResume: (() -> Void)? = nil
    var onSkip: (() -> Void)? = nil
    var onSeek: ((Int) -> Void)? = nil

    @State private var dragFraction: CGFloat?

    private var isLive: Bool { isPlaying && !isPaused }
    private var canSeek: Bool { onSeek != nil && durationSeconds > 0 }

    private func elapsedSeconds(at date: Date) -> Int {
        guard isLive, let observedAt = NaiveUTCDate.parse(positionObservedAt) else { return positionSeconds }
        let extrapolated = positionSeconds + Int(date.timeIntervalSince(observedAt).rounded())
        guard durationSeconds > 0 else { return max(extrapolated, positionSeconds) }
        return min(max(extrapolated, 0), durationSeconds)
    }

    var body: some View {
        PanelCard {
            HStack(alignment: .top, spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.isEmpty ? "Nothing playing right now" : title)
                        .font(.subheadline.bold())
                        .foregroundStyle(SwarmTheme.textPrimary)
                        .lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(SwarmTheme.textMuted)
                    }
                    HStack(spacing: 6) {
                        StatusPill(text: isLive ? "Playing" : (isPaused ? "Paused" : "Idle"), tone: isLive ? .live : (isPaused ? .soft : .off))
                        if let mediaSourceLabel, !mediaSourceLabel.isEmpty {
                            Text(mediaSourceLabel)
                                .font(.caption2.bold())
                                .foregroundStyle(SwarmTheme.textMuted)
                        }
                        if cached == true {
                            Label("Cached", systemImage: "internaldrive")
                                .font(.caption2)
                                .foregroundStyle(SwarmTheme.textMuted)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            if durationSeconds > 0 || positionSeconds > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let elapsed = dragFraction.map { Int($0 * CGFloat(max(durationSeconds, 1))) } ?? elapsedSeconds(at: timeline.date)
                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(SwarmTheme.panel2).frame(height: 6)
                                let fraction = durationSeconds > 0 ? CGFloat(elapsed) / CGFloat(durationSeconds) : 0
                                Capsule()
                                    .fill(SwarmTheme.accent)
                                    .frame(width: max(0, min(1, fraction)) * geo.size.width, height: 6)
                            }
                            .frame(maxHeight: .infinity, alignment: .center)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        guard canSeek else { return }
                                        dragFraction = max(0, min(1, value.location.x / max(geo.size.width, 1)))
                                    }
                                    .onEnded { value in
                                        guard canSeek else { return }
                                        let fraction = max(0, min(1, value.location.x / max(geo.size.width, 1)))
                                        onSeek?(Int(fraction * CGFloat(durationSeconds)))
                                        dragFraction = nil
                                    }
                            )
                        }
                        .frame(height: 20)
                        HStack {
                            Text(formatDuration(elapsed))
                            Spacer()
                            Text(durationSeconds > 0 ? formatDuration(durationSeconds) : "—")
                        }
                        .font(.caption2)
                        .foregroundStyle(SwarmTheme.textMuted)
                    }
                }
            }

            if onPause != nil || onResume != nil || onSkip != nil {
                HStack(spacing: 16) {
                    if isLive, let onPause {
                        Button { onPause() } label: {
                            Image(systemName: "pause.fill")
                                .frame(width: 44, height: 44)
                                .background(SwarmTheme.accent.opacity(0.15), in: Circle())
                        }
                    } else if let onResume {
                        Button { onResume() } label: {
                            Image(systemName: "play.fill")
                                .frame(width: 44, height: 44)
                                .background(SwarmTheme.accent.opacity(0.15), in: Circle())
                        }
                    }
                    if let onSkip {
                        Button { onSkip() } label: {
                            Image(systemName: "forward.fill")
                                .frame(width: 44, height: 44)
                                .background(SwarmTheme.panel2, in: Circle())
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if let thumbnailURL, let url = URL(string: thumbnailURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    thumbnailPlaceholder
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(shape)
        } else {
            thumbnailPlaceholder
                .frame(width: 56, height: 56)
                .clipShape(shape)
        }
    }

    private var thumbnailPlaceholder: some View {
        ZStack {
            SwarmTheme.panel2
            Image(systemName: "music.note")
                .foregroundStyle(SwarmTheme.accent)
        }
    }
}
