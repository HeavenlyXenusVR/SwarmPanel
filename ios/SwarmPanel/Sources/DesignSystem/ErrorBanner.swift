import SwiftUI
import UIKit

/// Replaces the bare `Text(error).foregroundStyle(.danger)` pattern repeated
/// across every screen with a banner that also lets the user copy the exact
/// error text — useful when reporting a backend issue, since these messages
/// often come straight from the server's `detail` field.
struct ErrorBanner: View {
    let message: String
    @EnvironmentObject private var toastCenter: ToastCenter

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(SwarmTheme.danger)
            Text(message)
                .font(.caption)
                .foregroundStyle(SwarmTheme.danger)
            Spacer(minLength: 8)
            Button {
                UIPasteboard.general.string = message
                Haptics.success()
                toastCenter.success("Copied")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(SwarmTheme.danger.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(SwarmTheme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
