import SwiftUI

/// Shimmering placeholder blocks shown during initial data loads — replaces
/// bare `ProgressView` spinners with a shape-of-the-content preview, matching
/// the web panel's skeleton-loader convention (components/ui.jsx's Skeleton).
private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    colors: [.clear, SwarmTheme.textPrimary.opacity(0.08), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .rotationEffect(.degrees(20))
                .offset(x: phase * 400)
            )
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 2
                }
            }
    }
}

private extension View {
    func shimmer() -> some View { modifier(ShimmerModifier()) }
}

struct SkeletonBlock: View {
    var height: CGFloat = 14
    var width: CGFloat? = nil
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(SwarmTheme.panel2)
            .frame(width: width, height: height)
            .shimmer()
    }
}

/// Skeleton shape for a single row inside a PanelCard list (SessionRow,
/// notification row, saved-queue row, etc.).
struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(SwarmTheme.panel2)
                .frame(width: 28, height: 28)
                .shimmer()
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(height: 12, width: 140)
                SkeletonBlock(height: 10, width: 90)
            }
            Spacer()
            SkeletonBlock(height: 18, width: 48, cornerRadius: 9)
        }
        .padding(14)
    }
}

/// A PanelCard-shaped placeholder for metric grids and quick-control cards.
struct SkeletonCard: View {
    var lines: Int = 2

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                SkeletonBlock(height: 14, width: 160)
                ForEach(0..<max(0, lines - 1), id: \.self) { _ in
                    SkeletonBlock(height: 10, width: 100)
                }
            }
        }
    }
}

/// A stack of `SkeletonRow`s inside a single zero-padding PanelCard, mirroring
/// the divider-separated list layout used by Dashboard/Leaderboard/etc.
struct SkeletonList: View {
    var rowCount: Int = 3

    var body: some View {
        PanelCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(0..<rowCount, id: \.self) { index in
                    if index > 0 {
                        Divider().overlay(SwarmTheme.line)
                    }
                    SkeletonRow()
                }
            }
        }
    }
}
