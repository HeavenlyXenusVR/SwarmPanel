import SwiftUI

/// GET /api/users/:account_id/profile — previously unreachable anywhere in
/// the app; tapping a user in Directory/Friends/Search only ever offered
/// Message/Follow/Friend-request buttons with no way to see who they
/// actually are.
struct PublicProfileView: View {
    @StateObject private var viewModel: PublicProfileViewModel

    init(accountId: Int) {
        _viewModel = StateObject(wrappedValue: PublicProfileViewModel(accountId: accountId))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if viewModel.isLoading && viewModel.profile == nil {
                    VStack(spacing: 14) {
                        SkeletonCard(lines: 4)
                        SkeletonCard(lines: 3)
                    }
                    .padding(.horizontal)
                } else if let profile = viewModel.profile {
                    header(profile)
                    stats(profile)
                    if let tags = profile.profileTags, !tags.isEmpty || profile.favoriteBot != nil {
                        chips(profile, tags: tags)
                    }
                    if let quote = profile.profileQuote, !quote.isEmpty {
                        PanelCard {
                            Text(quote).italic().foregroundStyle(SwarmTheme.textMuted)
                        }
                        .padding(.horizontal)
                    }
                    if let links = profile.profileLinks, !links.isEmpty {
                        linksSection(links)
                    }
                    if let activity = profile.activity {
                        activitySection(activity)
                    }
                } else if let error = viewModel.errorMessage {
                    PanelCard { ErrorBanner(message: error) }
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(SwarmTheme.background)
        .navigationTitle(viewModel.profile?.name ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }

    @ViewBuilder
    private func header(_ profile: PublicProfile) -> some View {
        PanelCard {
            HStack(spacing: 14) {
                InitialsAvatar(name: profile.name, diameter: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(.title3.bold()).foregroundStyle(SwarmTheme.textPrimary)
                    if let headline = profile.profileHeadline, !headline.isEmpty {
                        Text(headline).font(.subheadline).foregroundStyle(SwarmTheme.textMuted)
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(profile.isOnline == true ? SwarmTheme.ok : SwarmTheme.textMuted)
                            .frame(width: 7, height: 7)
                        Text(profile.isOnline == true ? "Online" : "Inactive")
                            .font(.caption2)
                            .foregroundStyle(SwarmTheme.textMuted)
                    }
                }
                Spacer()
            }
            if let bio = profile.bio, !bio.isEmpty {
                Text(bio).font(.callout).foregroundStyle(SwarmTheme.textPrimary)
            }
            actionRow(profile)
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func actionRow(_ profile: PublicProfile) -> some View {
        if profile.friendStatus != "self" {
            HStack(spacing: 10) {
                if viewModel.permissions?.canFollow == true || profile.followedByMe == true {
                    Button {
                        Task { await viewModel.toggleFollow() }
                    } label: {
                        Label(profile.followedByMe == true ? "Unfollow" : "Follow", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isActing)
                }
                if viewModel.permissions?.canFriend == true, !["friends", "pending_out"].contains(profile.friendStatus ?? "") {
                    Button {
                        Task { await viewModel.sendFriendRequest() }
                    } label: {
                        Label(profile.friendStatus == "pending_in" ? "Accept" : "Add Friend", systemImage: "person.2.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isActing)
                }
                if viewModel.permissions?.canMessage == true {
                    NavigationLink {
                        ThreadView(accountId: profile.id, peerName: profile.name)
                    } label: {
                        Label("Message", systemImage: "message.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SwarmTheme.accent)
                }
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func stats(_ profile: PublicProfile) -> some View {
        PanelCard {
            HStack {
                MetricTile(icon: "person.2.fill", label: "Followers", value: "\(profile.followerCount ?? 0)")
                MetricTile(icon: "person.crop.circle", label: "Following", value: "\(profile.followingCount ?? 0)")
                MetricTile(icon: "heart.fill", label: "Friends", value: "\(profile.friendCount ?? 0)")
                MetricTile(icon: "play.fill", label: "Plays", value: "\(profile.activity?.totalPlays ?? 0)")
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func chips(_ profile: PublicProfile, tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(tags.prefix(5), id: \.self) { tag in
                    Text(tag)
                        .font(.caption2.bold())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(SwarmTheme.panel2, in: Capsule())
                        .foregroundStyle(SwarmTheme.textMuted)
                }
                if let bot = profile.favoriteBot, !bot.isEmpty {
                    Text(bot.capitalized)
                        .font(.caption2.bold())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(SwarmTheme.accent.opacity(0.16), in: Capsule())
                        .foregroundStyle(SwarmTheme.accent)
                }
                Spacer()
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func linksSection(_ links: [ProfileLink]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Links")
            PanelCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                        if index > 0 { Divider().overlay(SwarmTheme.line) }
                        Link(destination: URL(string: link.url) ?? URL(string: "https://swarmpanel.xenusanimations.studio")!) {
                            HStack {
                                Text(link.label).foregroundStyle(SwarmTheme.textPrimary)
                                Spacer()
                                Image(systemName: "arrow.up.right").foregroundStyle(SwarmTheme.textMuted)
                            }
                            .padding(12)
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func activitySection(_ activity: PublicProfileActivity) -> some View {
        if let tracks = activity.topTracks, !tracks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "Top Tracks")
                PanelCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(tracks.prefix(5).enumerated()), id: \.element.id) { index, track in
                            if index > 0 { Divider().overlay(SwarmTheme.line) }
                            HStack {
                                Text(track.title ?? "Unknown title").foregroundStyle(SwarmTheme.textPrimary)
                                Spacer()
                                Text("\(track.plays ?? 0) plays").font(.caption2).foregroundStyle(SwarmTheme.textMuted)
                            }
                            .padding(12)
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

#Preview {
    NavigationStack { PublicProfileView(accountId: 1) }
        .environmentObject(ToastCenter())
}
