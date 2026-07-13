import UIKit

/// Thin wrapper over UIKit's feedback generators — used at the key action
/// points (control actions, saves, destructive confirms) so the app feels
/// native rather than silent, matching iOS platform conventions the web
/// panel obviously can't offer.
enum Haptics {
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    @MainActor static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    @MainActor static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    @MainActor static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    @MainActor static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    @MainActor static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}
