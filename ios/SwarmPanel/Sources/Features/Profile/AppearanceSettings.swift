import SwiftUI
import UIKit

/// Native appearance preferences: system/light/dark mode and an accent
/// color. Deliberately NOT a port of the web's CSS-driven panel_preferences
/// (surface_opacity, card_shape, panel_radius, etc. are meaningless outside
/// a web stylesheet) — just the two settings that make sense as native
/// SwiftUI concepts. The accent color is optionally pushed back to the
/// account's theme_accent field so it's consistent across the web and app.
@MainActor
final class AppearanceSettings: ObservableObject {
    @Published var colorSchemeOption: String {
        didSet { UserDefaults.standard.set(colorSchemeOption, forKey: Self.colorSchemeKey) }
    }
    @Published var accentColorHex: String {
        didSet { UserDefaults.standard.set(accentColorHex, forKey: Self.accentColorKey) }
    }

    private static let colorSchemeKey = "swarmpanel.colorSchemeOption"
    /// Not private: DesignSystem/Theme.swift reads the same UserDefaults key
    /// directly so static, non-view design-system helpers (StatusPill colors,
    /// etc.) can reflect the user's chosen accent without needing environment
    /// object plumbing into every leaf view.
    static let accentColorKey = "swarmpanel.accentColorHex"
    /// Matches the web panel's default --accent (frontend/src/styles.css).
    static let defaultAccentHex = "89B4FA"

    init() {
        colorSchemeOption = UserDefaults.standard.string(forKey: Self.colorSchemeKey) ?? "system"
        accentColorHex = UserDefaults.standard.string(forKey: Self.accentColorKey) ?? Self.defaultAccentHex
    }

    var colorScheme: ColorScheme? {
        switch colorSchemeOption {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var accentColor: Color {
        Color(hex: accentColorHex) ?? .accentColor
    }
}

extension Color {
    init?(hex: String) {
        let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard sanitized.count == 6, let value = UInt32(sanitized, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Best-effort hex string for persisting a user-picked accent color back
    /// to the account's theme_accent field.
    func toHex() -> String? {
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else { return nil }
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
}
