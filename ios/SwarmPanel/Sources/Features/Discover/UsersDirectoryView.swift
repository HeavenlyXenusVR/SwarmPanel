import SwiftUI

struct UsersDirectoryView: View {
    @StateObject private var viewModel = UsersDirectoryViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(SwarmTheme.textMuted)
                    TextField("Search users, servers, favorite bots", text: $viewModel.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await viewModel.load() } }
                }
                .padding(10)
                .background(SwarmTheme.panel2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal)

                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error).padding(.horizontal)
                }

                if viewModel.users.isEmpty && !viewModel.isLoading {
                    PanelCard { EmptyStateView(icon: "person.3", title: "No users found.") }
                        .padding(.horizontal)
                } else {
                    ForEach(viewModel.users) { user in
                        DirectoryUserCard(user: user) {
                            Task { await viewModel.follow(user.id, following: !user.isFollowedByMe) }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
        .background(SwarmTheme.background)
        .navigationTitle("Swarm Directory")
        .task { await viewModel.load() }
        .refreshable {
            Haptics.light()
            await viewModel.load()
        }
        .refreshOnForeground { await viewModel.load() }
    }
}

private struct DirectoryUserCard: View {
    let user: AccountSummary
    let onFollow: () -> Void

    var body: some View {
        PanelCard {
            HStack(spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.name).font(.headline).foregroundStyle(SwarmTheme.textPrimary)
                    Text(subtitle).font(.caption).foregroundStyle(SwarmTheme.textMuted)
                    if let favoriteBot = user.favoriteBot, !favoriteBot.isEmpty {
                        Text("Favorite bot: \(favoriteBot.capitalized)").font(.caption2).foregroundStyle(SwarmTheme.textMuted)
                    }
                }
                Spacer()
                Button(action: onFollow) {
                    Image(systemName: user.isFollowedByMe ? "person.fill.checkmark" : "person.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background((user.isFollowedByMe ? SwarmTheme.ok : SwarmTheme.accent).gradient, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var subtitle: String {
        user.serverName ?? user.profileHeadline ?? (user.guildId.map { "Guild \($0)" } ?? "Swarm directory")
    }

    @ViewBuilder
    private var avatar: some View {
        if let avatarUrlString = user.avatarUrl ?? user.serverIconUrl, let url = URL(string: avatarUrlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    InitialsAvatar(name: user.name, diameter: 44)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
        } else {
            InitialsAvatar(name: user.name, diameter: 44)
        }
    }
}

#Preview {
    NavigationStack { UsersDirectoryView() }
        .environmentObject(ToastCenter())
}
