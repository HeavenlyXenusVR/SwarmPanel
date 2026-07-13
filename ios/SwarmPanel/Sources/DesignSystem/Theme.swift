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

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
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

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tone.color.opacity(0.18), in: Capsule())
            .foregroundStyle(tone.color)
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

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(SwarmTheme.accent)
            Text(value)
                .font(.title3.bold())
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
