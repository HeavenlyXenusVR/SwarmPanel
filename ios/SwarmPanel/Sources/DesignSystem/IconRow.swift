import SwiftUI

/// Icon-chip + title row, matching iOS Settings' colored-icon navigation
/// rows — used for NavigationLink menus (Account, the Admin hub) so a list
/// reads as a scannable menu instead of a plain text list.
struct IconRow: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            IconChip(systemName: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(SwarmTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(SwarmTheme.textMuted)
                }
            }
        }
    }
}
