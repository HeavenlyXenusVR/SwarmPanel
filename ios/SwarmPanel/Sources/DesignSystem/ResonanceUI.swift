import SwiftUI
import UIKit

/// "Resonance" on iPhone and iPad: palette, surfaces and the components
/// every redesigned screen is built from. The platform-neutral pieces
/// (bot colours, hive geometry, the wave field, the equalizer) live in
/// Shared/Resonance.swift so the Apple TV app draws the same things.
///
/// The viewer's accent stays the one saturated colour that belongs to
/// *them*; each bot's own colour (BotPalette) marks things that belong to
/// that bot. Everything else is ink, glass and hairlines.
enum Res {
    // MARK: Palette

    /// Top of the backdrop gradient.
    static let skyTop = dynamic(light: 0xF3F6FB, dark: 0x060A11)
    /// Bottom of the backdrop gradient.
    static let skyBottom = dynamic(light: 0xE4ECF5, dark: 0x0B1320)
    /// Raised surface tint layered under the glass material.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x121C2A, lightAlpha: 0.74, darkAlpha: 0.62)
    /// A deeper inset surface (wells, tracks, segmented backgrounds).
    static let well = dynamic(light: 0x0B1320, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.06)
    /// Hairline used on every glass edge.
    static let hairline = dynamic(light: 0x0B1320, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.09)
    /// Muted text that still holds contrast on the backdrop.
    static let mist = dynamic(light: 0x55657A, dark: 0x93A3B8)
    /// Primary text.
    static let ink = dynamic(light: 0x0D1622, dark: 0xEEF3FA)

    static let live = BotPalette.rgb(0x5BD97E)
    static let warn = BotPalette.rgb(0xE8B366)
    static let danger = BotPalette.rgb(0xFF6B6B)

    // MARK: Shape

    enum Radius {
        static let chip: CGFloat = 14
        static let card: CGFloat = 22
        static let panel: CGFloat = 28
        static let hero: CGFloat = 32
    }

    // MARK: Type

    /// Display type for screen headers: rounded and heavy.
    static func display(_ size: CGFloat = 32) -> Font {
        .system(size: size, weight: .heavy, design: .rounded)
    }

    /// Instrument readouts: big numbers that shouldn't jitter as they tick.
    static func readout(_ size: CGFloat = 28) -> Font {
        .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
    }

    /// Small all-caps eyebrow labels above headers.
    static let eyebrow: Font = .system(size: 11, weight: .bold, design: .rounded)

    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let value = isDark ? dark : light
            return UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        })
    }
}

// MARK: - Environment

private struct ResAccentKey: EnvironmentKey {
    static var defaultValue: Color { SwarmTheme.accent }
}

extension EnvironmentValues {
    /// The viewer's accent. Set once at the app root from
    /// AppearanceSettings, so it updates live as they pick a new colour and
    /// still reaches sheets (environment values do; a missing environment
    /// object there would crash instead of falling back).
    var resAccent: Color {
        get { self[ResAccentKey.self] }
        set { self[ResAccentKey.self] = newValue }
    }
}

// MARK: - Backdrop

/// The studio sky every Resonance screen sits on: an ink gradient, two soft
/// glows in the viewer's accent, and slow sound-wave ribbons near the
/// bottom. The ribbons hold still under Reduce Motion.
struct ResonanceBackdrop: View {
    var showsWaves = true

    @Environment(\.resAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(colors: [Res.skyTop, Res.skyBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [accent.opacity(colorScheme == .dark ? 0.26 : 0.18), .clear],
                center: UnitPoint(x: 0.92, y: -0.04), startRadius: 8, endRadius: 440
            )
            RadialGradient(
                colors: [accent.hueShifted(by: 34).opacity(colorScheme == .dark ? 0.16 : 0.12), .clear],
                center: UnitPoint(x: -0.1, y: 0.62), startRadius: 8, endRadius: 380
            )
            if showsWaves {
                WaveField(
                    tint: accent,
                    secondary: accent.hueShifted(by: 34),
                    animated: !reduceMotion,
                    baseline: 0.86,
                    intensity: colorScheme == .dark ? 0.75 : 0.45
                )
            }
        }
    }
}

// MARK: - Surfaces

private struct ResGlass: ViewModifier {
    var radius: CGFloat
    var elevated: Bool
    var edge: Color?

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Res.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        edge.map { AnyShapeStyle(LinearGradient(colors: [$0.opacity(0.7), $0.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)) }
                            ?? AnyShapeStyle(Res.hairline),
                        lineWidth: edge == nil ? 1 : 1.5
                    )
            )
            .shadow(color: (edge ?? .black).opacity(elevated ? 0.24 : 0), radius: 18, x: 0, y: 10)
    }
}

private struct ResScreen: ViewModifier {
    var showsWaves: Bool

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(ResonanceBackdrop(showsWaves: showsWaves).ignoresSafeArea())
    }
}

extension View {
    /// A Resonance glass panel: material + tinted surface + hairline edge.
    /// Pass `edge` to give a hero surface a gradient rim in that colour.
    func resGlass(radius: CGFloat = Res.Radius.card, elevated: Bool = false, edge: Color? = nil) -> some View {
        modifier(ResGlass(radius: radius, elevated: elevated, edge: edge))
    }

    /// Puts a screen on the Resonance sky, and hides List/Form's own opaque
    /// grouped background so the sky shows through.
    func resonanceScreen(waves: Bool = true) -> some View {
        modifier(ResScreen(showsWaves: waves))
    }
}

// MARK: - Headers

/// The large header at the top of each dock destination: an eyebrow, a
/// display title, an optional subtitle and a trailing accessory.
struct ResScreenHeader<Accessory: View>: View {
    let eyebrow: String
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.resAccent) private var accent

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow.uppercased())
                    .font(Res.eyebrow)
                    .tracking(1.6)
                    .foregroundStyle(accent)
                Text(title)
                    .font(Res.display(34))
                    .foregroundStyle(Res.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Res.mist)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
    }
}

extension ResScreenHeader where Accessory == EmptyView {
    init(eyebrow: String, title: String, subtitle: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Eyebrow + title for a section within a screen, with an optional
/// trailing accessory ("See all", a count).
struct ResSectionHeader<Accessory: View>: View {
    let eyebrow: String?
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.resAccent) private var accent

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(Res.eyebrow)
                        .tracking(1.4)
                        .foregroundStyle(accent)
                }
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(Res.ink)
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 20)
    }
}

extension ResSectionHeader where Accessory == EmptyView {
    init(eyebrow: String? = nil, title: String) {
        self.init(eyebrow: eyebrow, title: title) { EmptyView() }
    }
}

// MARK: - Controls

/// Gentle press-down scale for tappable cards and chips.
struct ResPressStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Selectable pill used across filter shelves and segmented choices.
struct ResChip: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color? = nil
    var isSelected: Bool
    let action: () -> Void

    @Environment(\.resAccent) private var accent

    var body: some View {
        let color = tint ?? accent
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).imageScale(.small) }
                Text(title).lineLimit(1)
            }
            .font(.system(.footnote, design: .rounded).weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                if isSelected {
                    Capsule().fill(color)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                        .overlay(Capsule().strokeBorder(Res.hairline, lineWidth: 1))
                }
            }
            .foregroundStyle(isSelected ? Color.black.opacity(0.82) : Res.ink)
        }
        .buttonStyle(ResPressStyle())
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Full-width primary action: accent gradient with a soft glow.
struct ResPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.resAccent) private var accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isEnabled
                          ? AnyShapeStyle(LinearGradient(colors: [accent, accent.hueShifted(by: 34)], startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(Color.secondary.opacity(0.3)))
            )
            .foregroundStyle(isEnabled ? Color.black.opacity(0.85) : Color.secondary)
            .shadow(color: accent.opacity(isEnabled ? 0.35 : 0), radius: 14, x: 0, y: 6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Glass secondary action, same shape as the primary.
struct ResSecondaryButtonStyle: ButtonStyle {
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(tint ?? Res.ink)
            .resGlass(radius: 16)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Round transport button (play, pause, skip) used on the Now Playing deck.
struct ResTransportButton: View {
    let systemImage: String
    let label: String
    var prominent = false
    var size: CGFloat = 52
    let action: () -> Void

    @Environment(\.resAccent) private var accent

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(prominent ? Color.black.opacity(0.85) : Res.ink)
                .frame(width: size, height: size)
                .background {
                    if prominent {
                        Circle().fill(LinearGradient(colors: [accent, accent.hueShifted(by: 34)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .shadow(color: accent.opacity(0.45), radius: 12, y: 4)
                    } else {
                        Circle().fill(.ultraThinMaterial).overlay(Circle().fill(Res.surface))
                            .overlay(Circle().strokeBorder(Res.hairline, lineWidth: 1))
                    }
                }
        }
        .buttonStyle(ResPressStyle(scale: 0.9))
        .accessibilityLabel(label)
    }
}

// MARK: - Readouts

/// A single instrument readout: a big tabular number over an all-caps label.
struct ResReadout: View {
    let value: String
    let label: String
    var tint: Color? = nil
    var size: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Res.readout(size))
                .foregroundStyle(tint ?? Res.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(label.uppercased())
                .font(Res.eyebrow)
                .tracking(1)
                .foregroundStyle(Res.mist)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A glass list row: coloured icon tile, title, optional subtitle, and an
/// optional trailing value.
struct ResRow: View {
    let icon: String
    var tint: Color = .blue
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var showsChevron = false

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.gradient)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Res.ink)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(Res.mist).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.system(.subheadline, design: .rounded).monospacedDigit())
                    .foregroundStyle(Res.mist)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Res.mist.opacity(0.7))
            }
        }
        .contentShape(Rectangle())
    }
}

/// Live/paused/idle/offline badge with a breathing dot while live.
struct ResStatusBadge: View {
    let state: HiveCellState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

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
        case .playing: return Res.live
        case .paused: return Res.warn
        case .idle: return Res.mist
        case .offline: return Res.danger
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(state == .playing && breathe ? 0.35 : 1)
            Text(label)
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.16), in: Capsule())
        .foregroundStyle(color)
        .onAppear {
            guard state == .playing, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

// MARK: - Hive

/// One bot as the hive draws it.
struct HiveBot: Identifiable, Equatable {
    let key: String
    let name: String
    let state: HiveCellState
    /// Short line under the name (current track, "3 queued").
    var detail: String?
    var isOrchestrator = false

    var id: String { key }
}

/// The fleet as a honeycomb: Aria (or the first bot) in the centre and the
/// music bots in rings around it, each cell in the bot's own colour. A
/// playing bot's cell glows and breathes; an idle one is dim glass; an
/// offline one gets a red rim. Tapping a cell calls `onSelect`.
struct HiveMap: View {
    let bots: [HiveBot]
    var cellWidth: CGFloat = 74
    var onSelect: ((HiveBot) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ordered = orderedBots
        let positions = HiveLayout.positions(count: ordered.count)
        let gap: CGFloat = 1.08
        let xs = positions.map(\.x), ys = positions.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let cellHeight = cellWidth * 2 / sqrt(3)
        let width = (maxX - minX) * cellWidth * gap + cellWidth
        let height = (maxY - minY) * cellWidth * gap + cellHeight

        ZStack(alignment: .topLeading) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, bot in
                let point = positions[index]
                HiveCell(bot: bot, width: cellWidth, animated: !reduceMotion)
                    .position(
                        x: (point.x - minX) * cellWidth * gap + cellWidth / 2,
                        y: (point.y - minY) * cellWidth * gap + cellHeight / 2
                    )
                    .onTapGesture {
                        Haptics.light()
                        onSelect?(bot)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(bot.name), \(stateLabel(bot.state))")
                    .accessibilityValue(bot.detail ?? "")
                    .accessibilityAddTraits(onSelect == nil ? [] : .isButton)
                    .accessibilityAction { onSelect?(bot) }
            }
        }
        .frame(width: width, height: height)
    }

    /// Orchestrator first (it takes the centre), then fleet order.
    private var orderedBots: [HiveBot] {
        bots.sorted { a, b in
            if a.isOrchestrator != b.isOrchestrator { return a.isOrchestrator }
            let ia = BotPalette.fleetOrder.firstIndex(of: a.key.lowercased()) ?? Int.max
            let ib = BotPalette.fleetOrder.firstIndex(of: b.key.lowercased()) ?? Int.max
            return ia == ib ? a.key < b.key : ia < ib
        }
    }

    private func stateLabel(_ state: HiveCellState) -> String {
        switch state {
        case .playing: return "playing"
        case .paused: return "paused"
        case .idle: return "idle"
        case .offline: return "offline"
        }
    }
}

private struct HiveCell: View {
    let bot: HiveBot
    let width: CGFloat
    let animated: Bool

    @State private var breathe = false

    private var color: Color { BotPalette.color(for: bot.key) }
    private var lit: Bool { bot.state == .playing }

    var body: some View {
        let height = width * 2 / sqrt(3)
        ZStack {
            Hexagon()
                .fill(.ultraThinMaterial)
            Hexagon()
                .fill(
                    LinearGradient(
                        colors: [color.opacity(lit ? 0.7 : 0.16), color.opacity(lit ? 0.28 : 0.05)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            Hexagon()
                .stroke(
                    bot.state == .offline ? Res.danger.opacity(0.85) : color.opacity(lit ? 0.95 : 0.35),
                    lineWidth: lit ? 2 : 1.2
                )
            VStack(spacing: 3) {
                if bot.isOrchestrator {
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: width * 0.2, weight: .semibold))
                } else {
                    Text(BotPalette.monogram(for: bot.key, name: bot.name))
                        .font(.system(size: width * 0.24, weight: .heavy, design: .rounded))
                }
                if lit {
                    EqualizerBars(isActive: true, color: Color.white.opacity(0.9), barCount: 4,
                                  seed: bot.key.utf8.reduce(UInt64(7)) { $0 &* 31 &+ UInt64($1) }, animated: animated)
                        .frame(width: width * 0.26, height: width * 0.13)
                } else {
                    Circle()
                        .fill(bot.state == .offline ? Res.danger : (bot.state == .paused ? Res.warn : Res.mist.opacity(0.6)))
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(lit ? Color.white : Res.ink.opacity(bot.state == .offline ? 0.5 : 0.85))
        }
        .frame(width: width, height: height)
        .shadow(color: color.opacity(lit ? (breathe ? 0.75 : 0.4) : 0), radius: lit ? 14 : 0)
        .scaleEffect(lit && breathe ? 1.03 : 1)
        .opacity(bot.state == .offline ? 0.6 : 1)
        .onAppear { startBreathing() }
        .onChange(of: bot.state) { _ in startBreathing() }
    }

    private func startBreathing() {
        guard lit, animated else {
            breathe = false
            return
        }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
    }
}

// MARK: - List rows

/// Glass background for List/Form rows on Resonance screens. Rows sit over
/// the backdrop, so a flat opaque fill would hide it; this is material plus
/// the translucent surface tint.
struct ResRowBackground: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Rectangle().fill(Res.surface))
    }
}

