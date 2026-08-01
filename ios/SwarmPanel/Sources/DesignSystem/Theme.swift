import SwiftUI
import UIKit

/// Native color palette matching the web panel's design tokens
/// (frontend/src/styles.css's :root custom properties and its
/// .panel-theme-light overrides), so the app reads as the same product
/// instead of a generic system-styled screen. Each color is dynamic
/// (light/dark) via UITraitCollection, so it automatically follows
/// AppearanceSettings' .preferredColorScheme() the same way the rest of
/// SwiftUI does.
enum SwarmTheme {
    static var background: Color { dynamic(dark: 0x090D0F, light: 0xF6F8FB) }
    static var panel: Color { dynamic(dark: 0x11171B, light: 0xFFFFFF) }
    static var panel2: Color { dynamic(dark: 0x182127, light: 0xEEF3F8) }
    static var line: Color { dynamic(dark: 0x304047, light: 0xC9D3DF) }
    static var lineStrong: Color { dynamic(dark: 0x50656C, light: 0x9BADBF) }
    static var textPrimary: Color { dynamic(dark: 0xEDF3FB, light: 0x101823) }
    static var textMuted: Color { dynamic(dark: 0x9EABBC, light: 0x536172) }
    static var ok: Color { Color(hex: "5BD97E") ?? .green }
    static var warn: Color { Color(hex: "E8B366") ?? .orange }
    static var danger: Color { Color(hex: "FF6B6B") ?? .red }

    /// Reads the same UserDefaults key AppearanceSettings persists to —
    /// lets static, non-view helpers (MetricTile, InitialsAvatar) reflect the
    /// user's chosen accent without needing an @EnvironmentObject in every
    /// leaf view. Controls/toggles already pick this up automatically via
    /// the .tint() modifier applied at the app root.
    static var accent: Color {
        let hex = UserDefaults.standard.string(forKey: AppearanceSettings.accentColorKey) ?? AppearanceSettings.defaultAccentHex
        return Color(hex: hex) ?? Color(hex: AppearanceSettings.defaultAccentHex)!
    }

    static let cardRadius: CGFloat = 16

    /// "Swarm Pulse" redesign accents — additive, not replacing anything
    /// above (32 files already depend on those exact tokens). A second hue,
    /// offset from the user's chosen accent, turns every flat `accent` fill
    /// into a duotone gradient for hero/live elements — Dashboard's fleet
    /// cards, NowPlayingCard, and the new Command Center header — instead of
    /// a single flat swatch. Computed (not stored) so it always tracks
    /// whatever accent color the user picks in Profile.
    static var accentSecondary: Color {
        accent.hueShifted(by: 34)
    }

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accentSecondary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Faint radial glow anchored top-trailing, meant as a screen-level
    /// background layer (behind SwarmTheme.background, not replacing it) —
    /// gives Dashboard/Controls a "control room" depth instead of a flat
    /// fill, while staying subtle enough not to fight card content or hurt
    /// text contrast. Opt-in per screen via `.swarmBackdrop()`.
    static var backdropGlow: RadialGradient {
        RadialGradient(
            colors: [accent.opacity(0.16), .clear],
            center: .topTrailing,
            startRadius: 10,
            endRadius: 420
        )
    }

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

extension View {
    /// Layers SwarmTheme.background + backdropGlow behind the view — the
    /// "Swarm Pulse" screen backdrop. Applied per-screen (Dashboard,
    /// Controls, Profile's Command Center) rather than globally so
    /// list-heavy screens that already set `.scrollContentBackground(.hidden)`
    /// + `.background(SwarmTheme.background)` aren't forced to change.
    func swarmBackdrop() -> some View {
        background(
            ZStack {
                SwarmTheme.background
                SwarmTheme.backdropGlow
            }
            .ignoresSafeArea()
        )
    }
}

extension Color {
    /// Rotates this color's hue by `degrees` (0-360) at fixed saturation/
    /// brightness — used to derive accentSecondary from whatever single
    /// accent hex the user picked, without asking them to choose two colors.
    func hueShifted(by degrees: Double) -> Color {
        let ui = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        let shifted = (h * 360 + degrees).truncatingRemainder(dividingBy: 360) / 360
        return Color(hue: Double(shifted), saturation: Double(max(s, 0.55)), brightness: Double(max(b, 0.75)), opacity: Double(a))
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Session/status tone used across Dashboard, Controls, and Notifications —
/// mirrors the web's data-pill-{live|soft|off|danger} convention.
enum StatusTone {
    case live, soft, off, danger

    var color: Color {
        switch self {
        case .live: return SwarmTheme.ok
        case .soft: return SwarmTheme.warn
        case .off: return SwarmTheme.textMuted
        case .danger: return SwarmTheme.danger
        }
    }
}

struct StatusPill: View {
    let text: String
    let tone: StatusTone
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            if tone == .live {
                Circle()
                    .fill(tone.color)
                    .frame(width: 5, height: 5)
                    .opacity(pulse ? 0.35 : 1)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
            }
            Text(text)
        }
        .font(.caption2.bold())
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tone.color.opacity(0.18), in: Capsule())
        .foregroundStyle(tone.color)
    }
}

/// Colored rounded-square icon badge, matching iOS Settings/Shortcuts'
/// per-row icon chips — used to give list rows (Profile, Bot Detail stats)
/// a scannable identity instead of a uniform muted-gray SF Symbol.
struct IconChip: View {
    let systemName: String
    var tint: Color = SwarmTheme.accent
    var diameter: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: diameter * 0.3, style: .continuous)
            .fill(tint.gradient)
            .frame(width: diameter, height: diameter)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: diameter * 0.5, weight: .medium))
                    .foregroundStyle(.white)
            )
    }
}

/// IconChip + label + trailing value — the standard stat-row shape used on
/// Bot Detail and Controls' Current Session cards.
struct StatRow: View {
    let icon: String
    let tint: Color
    let label: String
    let value: String

    var body: some View {
        HStack {
            IconChip(systemName: icon, tint: tint)
            Text(label).foregroundStyle(SwarmTheme.textMuted)
            Spacer()
            Text(value).foregroundStyle(SwarmTheme.textPrimary)
        }
    }
}

/// Circular initials avatar — matches the web's IdentityAvatar fallback
/// (components/swarm.jsx) for accounts/users with no image.
struct InitialsAvatar: View {
    let name: String
    var diameter: CGFloat = 36

    private var initials: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [SwarmTheme.accent.opacity(0.9), SwarmTheme.accent.opacity(0.5)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .frame(width: diameter, height: diameter)
            .overlay(
                Text(initials)
                    .font(.system(size: diameter * 0.42, weight: .heavy))
                    .foregroundStyle(.white)
            )
    }
}

/// A single stat readout — mirrors the web's Metric/MetricGrid component
/// (components/ui.jsx).
struct MetricTile: View {
    let icon: String
    let label: String
    let value: String
    var tint: Color = SwarmTheme.accent

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(tint)
            Text(value)
                .font(.system(.title2, design: .rounded).bold())
                .foregroundStyle(SwarmTheme.textPrimary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(SwarmTheme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

/// Card container replacing default List/Form row chrome — mirrors the
/// web's shared .panel card look (dark surface, rounded corners, soft
/// shadow) used everywhere from bot cards to form panels.
struct PanelCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: { content })
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SwarmTheme.panel, in: RoundedRectangle(cornerRadius: SwarmTheme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SwarmTheme.cardRadius, style: .continuous)
                    .stroke(SwarmTheme.line, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }
}

/// Themed "nothing here yet" placeholder — replaces plain gray Text used for
/// empty lists (no sessions, no saved queues, no friends, etc.) with an icon
/// + message, matching the web's EmptyState component (components/ui.jsx).
struct EmptyStateView: View {
    var icon: String = "tray"
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(SwarmTheme.textMuted)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(SwarmTheme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}

struct SectionLabel: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.bold())
                .foregroundStyle(SwarmTheme.textMuted)
                .tracking(0.6)
            if let count {
                Text("\(count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(SwarmTheme.panel2, in: Capsule())
                    .foregroundStyle(SwarmTheme.textMuted)
            }
            Spacer()
        }
    }
}

// MARK: - "Swarm Pulse" redesign components (additive to the design system
// above — existing screens/components are untouched, these are opted into
// screen-by-screen: Dashboard's fleet cards, NowPlayingCard, and Profile's
// new Command Center header).

/// Concentric expanding rings behind a live indicator — the signature "swarm
/// pulse" motif standing in for StatusPill's single pulsing dot wherever a
/// screen wants a bigger, more ambient sense of "this bot is alive right
/// now" (a fleet card's corner badge, the Command Center header). Purely
/// decorative — layer it behind other content, it doesn't affect layout.
struct SwarmPulseRings: View {
    var color: Color = SwarmTheme.accent
    var ringCount: Int = 3
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<ringCount, id: \.self) { i in
                Circle()
                    .stroke(color.opacity(0.5), lineWidth: 1.5)
                    .scaleEffect(animate ? 2.2 : 0.4)
                    .opacity(animate ? 0 : 0.7)
                    .animation(
                        .easeOut(duration: 1.8)
                        .repeatForever(autoreverses: false)
                        .delay(Double(i) * (1.8 / Double(ringCount))),
                        value: animate
                    )
            }
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .onAppear { animate = true }
    }
}

/// Elevated alternative to PanelCard for hero/marquee content (a fleet
/// card's live session, NowPlayingCard, the Command Center header) — a
/// gradient-tinted border and soft glow instead of PanelCard's flat single-
/// color stroke, so a small number of "this is the important thing on
/// screen" surfaces read as a step up from the dozens of plain PanelCards
/// around them, without introducing a whole second visual language.
struct SwarmHeroCard<Content: View>: View {
    var padding: CGFloat = 18
    var tint: Color = SwarmTheme.accent
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: { content })
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SwarmTheme.panel, in: RoundedRectangle(cornerRadius: SwarmTheme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SwarmTheme.cardRadius, style: .continuous)
                    .stroke(
                        LinearGradient(colors: [tint.opacity(0.65), tint.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: tint.opacity(0.25), radius: 16, y: 6)
    }
}

/// Big glanceable number + label, styled for a marquee row (Command Center
/// header, fleet radar summary) — larger and gradient-tinted vs. MetricTile,
/// which stays as-is for the compact 3-up rows it's already used in
/// everywhere (Dashboard's Fleet card, BotDetailView).
struct SwarmStatBadge: View {
    let value: String
    let label: String
    var tint: Color = SwarmTheme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title, design: .rounded).weight(.heavy))
                .foregroundStyle(LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
            Text(label.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(SwarmTheme.textMuted)
                .tracking(0.5)
        }
    }
}
