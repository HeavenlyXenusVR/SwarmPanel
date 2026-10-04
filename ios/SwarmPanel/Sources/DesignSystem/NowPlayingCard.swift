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

/// "Now Playing" deck -- the Resonance centrepiece. The track's artwork is
/// blurred into an ambient glow behind a glass panel; the progress bar is a
/// waveform (its shape seeded from the title, so each track has its own
/// silhouette) that fills as the track plays and can be scrubbed to seek.
/// Position is extrapolated client-side from the last known position + its
/// observed-at timestamp, since the server only snapshots periodically.
/// Used interactively on Fleet and the Deck, read-only on Bot Detail.
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
    /// The bot's own colour, when the card belongs to one bot; otherwise
    /// the viewer's accent is used.
    var botKey: String? = nil
    var onPause: (() -> Void)? = nil
    var onResume: (() -> Void)? = nil
    var onSkip: (() -> Void)? = nil
    var onSeek: ((Int) -> Void)? = nil

    @State private var dragFraction: CGFloat?
    @Environment(\.resAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isLive: Bool { isPlaying && !isPaused }
    private var canSeek: Bool { onSeek != nil && durationSeconds > 0 }
    private var tint: Color { botKey.map(BotPalette.color(for:)) ?? accent }
    private var state: HiveCellState { isLive ? .playing : (isPaused ? .paused : .idle) }

    private func elapsedSeconds(at date: Date) -> Int {
        guard isLive, let observedAt = NaiveUTCDate.parse(positionObservedAt) else { return positionSeconds }
        let extrapolated = positionSeconds + Int(date.timeIntervalSince(observedAt).rounded())
        guard durationSeconds > 0 else { return max(extrapolated, positionSeconds) }
        return min(max(extrapolated, 0), durationSeconds)
    }

    private func currentElapsed(at date: Date) -> Int {
        if let dragFraction {
            return Int(dragFraction * CGFloat(max(durationSeconds, 1)))
        }
        return elapsedSeconds(at: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                artwork
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        ResStatusBadge(state: state)
                        if let mediaSourceLabel, !mediaSourceLabel.isEmpty {
                            Text(mediaSourceLabel.uppercased())
                                .font(Res.eyebrow)
                                .tracking(0.8)
                                .foregroundStyle(Res.mist)
                                .lineLimit(1)
                        }
                        if cached == true {
                            Image(systemName: "internaldrive")
                                .font(.caption2)
                                .foregroundStyle(Res.mist)
                                .accessibilityLabel("Cached")
                        }
                    }
                    Text(title.isEmpty ? "Nothing playing right now" : title)
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(Res.ink)
                        .lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(Res.mist)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isLive {
                    EqualizerBars(isActive: true, color: tint, barCount: 4, seed: 3, animated: !reduceMotion)
                        .frame(width: 22, height: 20)
                }
            }

            if durationSeconds > 0 || positionSeconds > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    // The gesture-bearing GeometryReader is created ONCE, not
                    // re-evaluated every tick -- only the waveform fill and
                    // labels update live via their own TimelineViews.
                    // Rebuilding a view that owns an active gesture recognizer
                    // every second risked the drag being torn down mid-touch.
                    GeometryReader { geo in
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            let elapsed = currentElapsed(at: timeline.date)
                            let fraction = durationSeconds > 0 ? CGFloat(elapsed) / CGFloat(durationSeconds) : 0
                            WaveformTrack(seed: title, progress: max(0, min(1, fraction)), tint: tint, scrubbing: dragFraction != nil)
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            // minimumDistance > 0 so a simple tap (e.g. from a
                            // parent NavigationLink/context menu) never gets
                            // misread as a scrub-to-zero seek.
                            DragGesture(minimumDistance: 8)
                                .onChanged { value in
                                    guard canSeek else { return }
                                    if dragFraction == nil { Haptics.selection() }
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
                    .frame(height: 34)
                    .accessibilityElement()
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(formatDuration(positionSeconds)) of \(formatDuration(durationSeconds))")
                    HStack {
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            Text(formatDuration(currentElapsed(at: timeline.date)))
                        }
                        Spacer()
                        Text(durationSeconds > 0 ? formatDuration(durationSeconds) : "—")
                    }
                    .font(.system(.caption2, design: .rounded).monospacedDigit())
                    .foregroundStyle(Res.mist)
                }
            }

            if onPause != nil || onResume != nil || onSkip != nil {
                HStack(spacing: 18) {
                    Spacer()
                    if isLive, let onPause {
                        ResTransportButton(systemImage: "pause.fill", label: "Pause", prominent: true, size: 58) { onPause() }
                    } else if let onResume {
                        ResTransportButton(systemImage: "play.fill", label: "Resume", prominent: true, size: 58) { onResume() }
                    }
                    if let onSkip {
                        ResTransportButton(systemImage: "forward.fill", label: "Skip", size: 46) { onSkip() }
                    }
                    Spacer()
                }
                .disabled(isBusy)
                .opacity(isBusy ? 0.55 : 1)
                .overlay(alignment: .trailing) {
                    if isBusy { ProgressView().padding(.trailing, 4) }
                }
            }
        }
        .padding(18)
        .background(ambientGlow.clipShape(RoundedRectangle(cornerRadius: Res.Radius.panel, style: .continuous)))
        .resGlass(radius: Res.Radius.panel, elevated: true, edge: isLive ? tint : nil)
    }

    /// The artwork, blurred and spread behind the whole card.
    @ViewBuilder
    private var ambientGlow: some View {
        ZStack {
            if let thumbnailURL, let url = URL(string: thumbnailURL) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        tint.opacity(0.25)
                    }
                }
                .blur(radius: 40)
                .opacity(0.55)
            } else {
                RadialGradient(colors: [tint.opacity(0.35), .clear], center: .topLeading, startRadius: 4, endRadius: 260)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Group {
            if let thumbnailURL, let url = URL(string: thumbnailURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        artworkPlaceholder
                    }
                }
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(shape)
        .overlay(shape.strokeBorder(tint.opacity(isLive ? 0.8 : 0.25), lineWidth: 1.5))
        .shadow(color: tint.opacity(isLive ? 0.45 : 0), radius: 12, y: 4)
    }

    private var artworkPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

/// The scrubber: a row of bars shaped like a waveform, filled up to
/// `progress`. Bar heights are seeded from `seed` (the track title), so the
/// same track always draws the same silhouette.
struct WaveformTrack: View {
    let seed: String
    let progress: CGFloat
    let tint: Color
    var scrubbing = false

    private var heights: [CGFloat] {
        var generator = ResonanceRandom(seed: seed.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 })
        return (0..<56).map { index in
            // A soft swell in the middle, randomised per bar.
            let position = Double(index) / 55
            let swell = 0.45 + 0.4 * sin(position * .pi)
            return CGFloat(min(1, max(0.14, swell * Double.random(in: 0.55...1.15, using: &generator))))
        }
    }

    var body: some View {
        let bars = heights
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let barWidth = max((geo.size.width - spacing * CGFloat(bars.count - 1)) / CGFloat(bars.count), 1)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, height in
                    let filled = CGFloat(index) / CGFloat(bars.count) < progress
                    Capsule()
                        .fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(Res.mist.opacity(0.28)))
                        .frame(width: barWidth, height: geo.size.height * height * (scrubbing && filled ? 1.08 : 1))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.25), value: progress)
    }
}
