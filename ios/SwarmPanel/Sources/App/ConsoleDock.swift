import SwiftUI

/// The floating console dock: a glass capsule with the four destinations
/// either side of the raised Deck orb. The selected destination grows into
/// a labelled pill (a matched-geometry highlight slides between them), so
/// the dock stays compact without hiding where you are. The orb itself is
/// a slowly turning ring of the fleet's own colours -- the hive, folded
/// into one button.
struct ConsoleDock: View {
    let selection: SwarmTab
    let communityBadge: Int
    let onSelect: (SwarmTab) -> Void
    let onDeck: () -> Void

    @Namespace private var highlight
    @Environment(\.resAccent) private var accent

    var body: some View {
        HStack(spacing: 4) {
            item(.fleet)
            item(.insights)
            deckOrb
            item(.community)
            item(.account)
        }
        .padding(6)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Res.surface))
        )
        .overlay(Capsule().strokeBorder(Res.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 20, x: 0, y: 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func item(_ tab: SwarmTab) -> some View {
        let isSelected = selection == tab
        let badge = tab == .community ? communityBadge : 0
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { onSelect(tab) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? tab.selectedIcon : tab.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text(badge > 99 ? "99+" : "\(badge)")
                                .font(.system(size: 9, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Res.danger, in: Capsule())
                                .offset(x: 10, y: -8)
                        }
                    }
                if isSelected {
                    Text(tab.title)
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
            }
            .foregroundStyle(isSelected ? accent : Res.mist)
            .padding(.horizontal, isSelected ? 14 : 10)
            .frame(height: 46)
            .frame(maxWidth: isSelected ? nil : .infinity)
            .background {
                if isSelected {
                    Capsule()
                        .fill(accent.opacity(0.16))
                        .matchedGeometryEffect(id: "highlight", in: highlight)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(ResPressStyle(scale: 0.92))
        .accessibilityLabel(tab.title)
        .accessibilityValue(badge > 0 ? "\(badge) unread" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var deckOrb: some View {
        Button(action: onDeck) {
            DeckOrbFace()
        }
        .buttonStyle(ResPressStyle(scale: 0.88))
        .padding(.horizontal, 4)
        .accessibilityLabel("Open the Deck")
        .accessibilityHint("Send play, pause, skip and other orders to a bot")
    }
}

/// The orb's face: an angular ring of every bot's colour turning slowly
/// around a dark core with the Deck glyph. Holds still under Reduce Motion.
private struct DeckOrbFace: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ringColors: [Color] {
        let colors = BotPalette.fleetOrder.map(BotPalette.color(for:))
        return colors + [colors.first ?? .white]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let angle = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 24) / 24 * 360
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: ringColors, center: .center, angle: .degrees(angle)))
                Circle()
                    .fill(Res.dynamic(light: 0x0D1622, dark: 0x0A111C))
                    .padding(4)
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .shadow(color: BotPalette.color(for: "glitch").opacity(0.25), radius: 10, x: 0, y: 4)
        }
    }
}
