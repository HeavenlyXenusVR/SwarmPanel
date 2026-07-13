import SwiftUI

struct LeaderboardView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = LeaderboardViewModel()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Bot", selection: $viewModel.selectedBotKey) {
                        ForEach(viewModel.bots) { bot in
                            Text(bot.label).tag(bot.id)
                        }
                    }
                    TextField("Guild ID", text: $viewModel.guildId)
                        .keyboardType(.numberPad)
                }

                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section("Top Tracks") {
                    let tracks = viewModel.data?.topTracks ?? []
                    if tracks.isEmpty {
                        Text("No track history yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            HStack {
                                Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 24)
                                VStack(alignment: .leading) {
                                    Text(track.title?.isEmpty == false ? track.title! : "Untitled")
                                        .lineLimit(1)
                                    Text("\(track.playCount ?? 0) plays · \(track.likeCount ?? 0) likes")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Top Listeners") {
                    let listeners = viewModel.data?.topListeners ?? []
                    if listeners.isEmpty {
                        Text("No listener history yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(listeners.enumerated()), id: \.element.id) { index, listener in
                            HStack {
                                Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 24)
                                VStack(alignment: .leading) {
                                    Text("Listener \(listener.userId.map(String.init) ?? "?")")
                                    Text("\(listener.trackCount ?? 0) tracks · \(listener.playCount ?? 0) plays")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if viewModel.isLoading && viewModel.data == nil {
                    ProgressView("Loading leaderboard...")
                }
            }
            .navigationTitle("Leaderboard")
            .task {
                if viewModel.guildId.isEmpty { viewModel.guildId = appState.guildId ?? "" }
                await viewModel.loadBots()
                await viewModel.loadLeaderboard()
            }
            .onChange(of: viewModel.selectedBotKey) { _ in
                Task { await viewModel.loadLeaderboard() }
            }
            .onChange(of: viewModel.guildId) { _ in
                Task { await viewModel.loadLeaderboard() }
            }
            .refreshable { await viewModel.loadLeaderboard() }
        }
    }
}

#Preview {
    LeaderboardView()
        .environmentObject(AppState())
}
