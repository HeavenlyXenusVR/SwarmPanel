import SwiftUI

struct WhatsNewView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(releaseNotes) { note in
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(title: "Version \(note.version)")
                        PanelCard {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(note.highlights, id: \.self) { highlight in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "sparkle")
                                            .font(.caption)
                                            .foregroundStyle(SwarmTheme.accent)
                                        Text(highlight)
                                            .font(.caption)
                                            .foregroundStyle(SwarmTheme.textPrimary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(SwarmTheme.background)
        .navigationTitle("What's New")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { WhatsNewView() }
}
