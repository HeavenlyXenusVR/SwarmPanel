import SwiftUI
import UIKit

/// Drill-down from a Dashboard session row into that bot+guild's full
/// control-state — same endpoint the Controls screen uses, just presented
/// read-only here since Controls already covers taking action.
struct BotDetailView: View {
    let botKey: String
    let botDisplayName: String
    let guildId: String
    @StateObject private var viewModel = BotDetailViewModel()
    @EnvironmentObject private var toastCenter: ToastCenter
    @EnvironmentObject private var recentBots: RecentBotsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(SwarmTheme.danger).padding(.horizontal)
                }
                if let session = viewModel.session {
                    PanelCard {
                        Text(session.title?.isEmpty == false ? session.title! : "Nothing playing")
                            .font(.headline)
                            .foregroundStyle(SwarmTheme.textPrimary)
                        StatusPill(
                            text: session.sessionStateLabel ?? "Unknown",
                            tone: session.isPlaying == true && session.isPaused != true ? .live : .off
                        )
                        Divider().overlay(SwarmTheme.line)
                        LabeledContent("Queue", value: "\(session.queueCount ?? 0)")
                        LabeledContent("Backup Queue", value: "\(session.backupQueueCount ?? 0)")
                        if let loopMode = session.loopMode {
                            LabeledContent("Loop", value: loopMode.capitalized)
                        }
                        if let filterMode = session.filterMode {
                            LabeledContent("Filter", value: filterMode.capitalized)
                        }
                    }
                    .padding(.horizontal)

                    if let items = session.queuePreview, !items.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel(title: "Up Next", count: items.count)
                            PanelCard(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                                        if index > 0 { Divider().overlay(SwarmTheme.line) }
                                        Text(item.title?.isEmpty == false ? item.title! : item.videoUrl)
                                            .font(.caption)
                                            .foregroundStyle(SwarmTheme.textPrimary)
                                            .lineLimit(1)
                                            .padding(12)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                guard let url = URL(string: item.videoUrl) else { return }
                                                UIApplication.shared.open(url)
                                            }
                                            .contextMenu {
                                                Button {
                                                    UIPasteboard.general.string = item.videoUrl
                                                    Haptics.success()
                                                    toastCenter.success("Link copied")
                                                } label: {
                                                    Label("Copy Link", systemImage: "doc.on.doc")
                                                }
                                                Button {
                                                    guard let url = URL(string: item.videoUrl) else { return }
                                                    UIApplication.shared.open(url)
                                                } label: {
                                                    Label("Open in Safari", systemImage: "safari")
                                                }
                                            }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                } else if viewModel.isLoading {
                    SkeletonCard(lines: 4).padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(SwarmTheme.background)
        .navigationTitle(botDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load(botKey: botKey, guildId: guildId)
            recentBots.record(botKey: botKey, guildId: guildId, displayName: botDisplayName)
        }
        .refreshable {
            Haptics.light()
            await viewModel.load(botKey: botKey, guildId: guildId)
        }
    }
}
