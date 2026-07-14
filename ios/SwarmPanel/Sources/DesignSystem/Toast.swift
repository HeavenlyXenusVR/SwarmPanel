import SwiftUI

/// Lightweight transient message surface — "Copied", "Saved", "Deleted" — so
/// actions that previously relied on haptics alone (the only feedback a user
/// gets if they're not looking right at the button) get a visible
/// confirmation too. One instance is owned by RootTabView and injected via
/// environment so any screen can call `toast.show(...)`.
@MainActor
final class ToastCenter: ObservableObject {
    struct Message: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let systemImage: String
        let tone: StatusTone
    }

    @Published private(set) var current: Message?
    private var dismissTask: Task<Void, Never>?

    func show(_ text: String, systemImage: String = "checkmark.circle.fill", tone: StatusTone = .live) {
        dismissTask?.cancel()
        current = Message(text: text, systemImage: systemImage, tone: tone)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    func success(_ text: String) { show(text, systemImage: "checkmark.circle.fill", tone: .live) }
    func failure(_ text: String) { show(text, systemImage: "exclamationmark.triangle.fill", tone: .danger) }
}

private struct ToastOverlay: View {
    @ObservedObject var center: ToastCenter

    var body: some View {
        VStack {
            Spacer()
            if let message = center.current {
                HStack(spacing: 8) {
                    Image(systemName: message.systemImage)
                        .foregroundStyle(message.tone.color)
                    Text(message.text)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(SwarmTheme.textPrimary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(SwarmTheme.panel, in: Capsule())
                .overlay(Capsule().stroke(SwarmTheme.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: center.current)
        .allowsHitTesting(false)
    }
}

extension View {
    func toastOverlay(_ center: ToastCenter) -> some View {
        overlay(ToastOverlay(center: center))
    }
}
