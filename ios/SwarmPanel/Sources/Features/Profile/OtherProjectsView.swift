import SwiftUI

/// Mirrors web's /other-projects — previously had no iOS equivalent at all.
struct OtherProjectsView: View {
    @StateObject private var viewModel = OtherProjectsViewModel()
    @State private var shareURL: IdentifiableURL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error).padding(.horizontal)
                }

                Link(destination: URL(string: "https://gallery.xenusanimations.studio")!) {
                    ProjectCard(
                        image: "photo.stack.fill", tint: .purple,
                        title: "Image Gallery",
                        subtitle: "Curated media deck for uploads, collections, and social feeds.",
                        cta: "Open"
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal)

                Button {
                    Task {
                        if let url = await viewModel.downloadLumisound() {
                            shareURL = IdentifiableURL(url: url)
                        }
                    }
                } label: {
                    ProjectCard(
                        image: "waveform", tint: .pink,
                        title: "Lumisound",
                        subtitle: "iOS music app. Downloads the latest build straight from GitHub.",
                        cta: viewModel.isDownloading ? "Fetching…" : "Download latest",
                        isLoading: viewModel.isDownloading
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isDownloading)
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(SwarmTheme.background)
        .navigationTitle("My Other Projects")
        .sheet(item: $shareURL) { item in
            ActivityShareSheet(activityItems: [item.url])
        }
    }
}

private struct ProjectCard: View {
    let image: String
    let tint: Color
    let title: String
    let subtitle: String
    let cta: String
    var isLoading: Bool = false

    var body: some View {
        PanelCard {
            HStack(spacing: 14) {
                IconChip(systemName: image, tint: tint, diameter: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(SwarmTheme.textPrimary)
                    Text(subtitle).font(.caption).foregroundStyle(SwarmTheme.textMuted)
                }
                Spacer()
                if isLoading {
                    ProgressView()
                } else {
                    HStack(spacing: 4) {
                        Text(cta).font(.caption.bold())
                        Image(systemName: "arrow.up.right")
                    }
                    .foregroundStyle(tint)
                }
            }
        }
    }
}

#Preview {
    NavigationStack { OtherProjectsView() }
        .environmentObject(ToastCenter())
}
