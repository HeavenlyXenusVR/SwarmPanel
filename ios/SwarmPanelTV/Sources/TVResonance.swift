import SwiftUI

/// Resonance on Apple TV: the same studio sky, hive and equalizers as the
/// iPhone app (see Shared/Resonance.swift), sized for a room and driven by
/// focus instead of touch. The account's own background (preset colour,
/// custom colour or image, set on the web) is still the base layer; the
/// Resonance glow and waves sit on top of it.

enum TVRes {
    static let ink = Color.white
    static let mist = Color(red: 0.62, green: 0.68, blue: 0.76)
    static let surface = Color(red: 0.07, green: 0.11, blue: 0.16).opacity(0.62)
    static let hairline = Color.white.opacity(0.1)
    static let live = BotPalette.rgb(0x5BD97E)
    static let warn = BotPalette.rgb(0xE8B366)
    static let danger = BotPalette.rgb(0xFF6B6B)

    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .rounded)
    }

    static func readout(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
    }

    static let eyebrow: Font = .system(size: 20, weight: .bold, design: .rounded)
}

// MARK: - Surfaces

private struct TVGlass: ViewModifier {
    var radius: CGFloat
    var edge: Color?

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(TVRes.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        edge.map { AnyShapeStyle(LinearGradient(colors: [$0.opacity(0.8), $0.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)) }
                            ?? AnyShapeStyle(TVRes.hairline),
                        lineWidth: edge == nil ? 1.5 : 2.5
                    )
            )
    }
}

extension View {
    /// A Resonance glass panel for the TV.
    func tvGlass(radius: CGFloat = 28, edge: Color? = nil) -> some View {
        modifier(TVGlass(radius: radius, edge: edge))
    }
}

/// The glow + wave layer drawn over the account's background.
struct TVResonanceOverlay: View {
    let accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RadialGradient(colors: [accent.opacity(0.28), .clear], center: UnitPoint(x: 0.95, y: -0.05), startRadius: 20, endRadius: 900)
            RadialGradient(colors: [accent.opacity(0.12), .clear], center: UnitPoint(x: -0.05, y: 0.75), startRadius: 20, endRadius: 800)
            WaveField(tint: accent, secondary: accent.opacity(0.7), animated: !reduceMotion, ribbonCount: 5, baseline: 0.88, intensity: 0.7)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Readouts

struct TVReadout: View {
    let value: String
    let label: String
    var tint: Color = TVRes.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(TVRes.readout(52))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label.uppercased())
                .font(TVRes.eyebrow)
                .tracking(1.5)
                .foregroundStyle(TVRes.mist)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Live/paused/idle/offline badge.
struct TVStateBadge: View {
    let state: HiveCellState

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(label)
        }
        .font(.system(size: 22, weight: .bold, design: .rounded))
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(color.opacity(0.18), in: Capsule())
        .foregroundStyle(color)
    }

    private var label: String {
        switch state {
        case .playing: return "Live"
        case .paused: return "Paused"
        case .idle: return "Idle"
        case .offline: return "Offline"
        }
    }

    private var color: Color {
        switch state {
        case .playing: return TVRes.live
        case .paused: return TVRes.warn
        case .idle: return TVRes.mist
        case .offline: return TVRes.danger
        }
    }
}

extension TVBot {
    /// How the hive draws this bot.
    var hiveState: HiveCellState {
        if isOffline { return .offline }
        let all = sessions ?? []
        if all.contains(where: { $0.isPlaying == true && $0.isPaused != true }) || (activePlayingCount ?? 0) > 0 { return .playing }
        if all.contains(where: { $0.isPaused == true }) { return .paused }
        return .idle
    }
}

// MARK: - Hive

/// The fleet as a focusable honeycomb. Each cell is a button: focusing it
/// lifts and lights it (and shows the bot's name and track underneath the
/// hive); selecting it opens that bot.
struct TVHiveMap: View {
    let bots: [TVBot]
    var cellWidth: CGFloat = 150
    let onSelect: (TVBot) -> Void
    @Binding var focusedKey: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ordered = bots.sorted { a, b in
            if a.isOrchestrator != b.isOrchestrator { return a.isOrchestrator }
            let ia = BotPalette.fleetOrder.firstIndex(of: a.key.lowercased()) ?? Int.max
            let ib = BotPalette.fleetOrder.firstIndex(of: b.key.lowercased()) ?? Int.max
            return ia == ib ? a.key < b.key : ia < ib
        }
        let positions = HiveLayout.positions(count: ordered.count)
        let gap: CGFloat = 1.1
        let xs = positions.map(\.x), ys = positions.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let cellHeight = cellWidth * 2 / sqrt(3)

        ZStack(alignment: .topLeading) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, bot in
                let point = positions[index]
                Button { onSelect(bot) } label: {
                    TVHiveCell(bot: bot, width: cellWidth, animated: !reduceMotion, focusedKey: $focusedKey)
                }
                .buttonStyle(TVHexButtonStyle())
                .position(
                    x: (point.x - minX) * cellWidth * gap + cellWidth / 2,
                    y: (point.y - minY) * cellWidth * gap + cellHeight / 2
                )
                .accessibilityLabel(bot.name)
            }
        }
        .frame(
            width: (maxX - minX) * cellWidth * gap + cellWidth,
            height: (maxY - minY) * cellWidth * gap + cellHeight
        )
    }
}

/// Plain press feedback; the focus look lives in TVHiveCell, which can read
/// `isFocused` from inside the button.
private struct TVHexButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct TVHiveCell: View {
    let bot: TVBot
    let width: CGFloat
    let animated: Bool
    @Binding var focusedKey: String?

    @Environment(\.isFocused) private var isFocused
    @State private var breathe = false

    private var color: Color { BotPalette.color(for: bot.key) }
    private var lit: Bool { bot.hiveState == .playing }

    var body: some View {
        let height = width * 2 / sqrt(3)
        ZStack {
            Hexagon().fill(.ultraThinMaterial)
            Hexagon().fill(
                LinearGradient(
                    colors: [color.opacity(lit || isFocused ? 0.75 : 0.18), color.opacity(lit || isFocused ? 0.3 : 0.05)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            Hexagon().stroke(
                bot.hiveState == .offline ? TVRes.danger : color.opacity(lit || isFocused ? 1 : 0.4),
                lineWidth: isFocused ? 5 : (lit ? 3 : 2)
            )
            VStack(spacing: 8) {
                if bot.isOrchestrator {
                    Image(systemName: "gearshape.2.fill").font(.system(size: width * 0.22, weight: .semibold))
                } else {
                    Text(BotPalette.monogram(for: bot.key, name: bot.displayName))
                        .font(.system(size: width * 0.24, weight: .heavy, design: .rounded))
                }
                if lit {
                    EqualizerBars(isActive: true, color: .white.opacity(0.9), barCount: 4,
                                  seed: bot.key.utf8.reduce(UInt64(7)) { $0 &* 31 &+ UInt64($1) }, animated: animated)
                        .frame(width: width * 0.26, height: width * 0.12)
                } else {
                    Circle()
                        .fill(bot.hiveState == .offline ? TVRes.danger : (bot.hiveState == .paused ? TVRes.warn : TVRes.mist.opacity(0.6)))
                        .frame(width: 10, height: 10)
                }
            }
            .foregroundStyle(lit || isFocused ? Color.white : TVRes.ink.opacity(bot.hiveState == .offline ? 0.5 : 0.85))
        }
        .frame(width: width, height: height)
        .shadow(color: color.opacity(isFocused ? 0.9 : (lit ? (breathe ? 0.7 : 0.35) : 0)), radius: isFocused ? 30 : 18)
        .scaleEffect(isFocused ? 1.14 : (lit && breathe ? 1.03 : 1))
        .opacity(bot.hiveState == .offline && !isFocused ? 0.6 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .onChange(of: isFocused) { _, focused in
            if focused { focusedKey = bot.key } else if focusedKey == bot.key { focusedKey = nil }
        }
        .onAppear {
            guard lit, animated else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}
