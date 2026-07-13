import SwiftUI

struct SocialView: View {
    @EnvironmentObject private var notificationsViewModel: NotificationsViewModel
    @StateObject private var viewModel = SocialViewModel()

    var body: some View {
        NavigationStack {
            List {
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(SwarmTheme.danger) }
                        .listRowBackground(SwarmTheme.panel)
                }

                Section {
                    HStack {
                        TextField("Search username or display name", text: $viewModel.searchQuery)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await viewModel.search() } }
                        Button("Search") { Task { await viewModel.search() } }
                            .tint(SwarmTheme.accent)
                    }
                    ForEach(viewModel.searchResults) { user in
                        HStack(spacing: 10) {
                            InitialsAvatar(name: user.name, diameter: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(user.name).foregroundStyle(SwarmTheme.textPrimary)
                                if let server = user.serverName {
                                    Text(server).font(.caption).foregroundStyle(SwarmTheme.textMuted)
                                }
                            }
                            Spacer()
                            Button { Task { await viewModel.follow(user.id) } } label: {
                                Image(systemName: "person.badge.plus")
                            }
                            .buttonStyle(.borderless)
                            .tint(SwarmTheme.accent)
                            Button { Task { await viewModel.sendFriendRequest(user.id) } } label: {
                                Image(systemName: "person.2")
                            }
                            .buttonStyle(.borderless)
                            .tint(SwarmTheme.accent)
                            NavigationLink {
                                ThreadView(accountId: user.id, peerName: user.name)
                            } label: {
                                Image(systemName: "message")
                            }
                            .tint(SwarmTheme.accent)
                        }
                    }
                } header: {
                    SectionLabel(title: "Find People")
                }
                .listRowBackground(SwarmTheme.panel)

                if !viewModel.incomingRequests.isEmpty {
                    Section {
                        ForEach(viewModel.incomingRequests) { request in
                            HStack(spacing: 10) {
                                InitialsAvatar(name: request.name, diameter: 32)
                                Text(request.name).foregroundStyle(SwarmTheme.textPrimary)
                                Spacer()
                                Button("Accept") { Task { await viewModel.respondToRequest(request, action: "accept") } }
                                    .buttonStyle(.borderless)
                                    .tint(SwarmTheme.ok)
                                Button("Decline") { Task { await viewModel.respondToRequest(request, action: "decline") } }
                                    .buttonStyle(.borderless)
                                    .tint(SwarmTheme.danger)
                            }
                        }
                    } header: {
                        SectionLabel(title: "Friend Requests", count: viewModel.incomingRequests.count)
                    }
                    .listRowBackground(SwarmTheme.panel)
                }

                if !viewModel.outgoingRequests.isEmpty {
                    Section {
                        ForEach(viewModel.outgoingRequests) { request in
                            HStack {
                                Text(request.name).foregroundStyle(SwarmTheme.textPrimary)
                                Spacer()
                                StatusPill(text: request.status?.capitalized ?? "Pending", tone: .soft)
                            }
                        }
                    } header: {
                        SectionLabel(title: "Sent Requests")
                    }
                    .listRowBackground(SwarmTheme.panel)
                }

                Section {
                    if viewModel.friends.isEmpty {
                        EmptyStateView(icon: "person.2.slash", title: "No friends yet.")
                    } else {
                        ForEach(viewModel.friends) { friend in
                            NavigationLink {
                                ThreadView(accountId: friend.id, peerName: friend.name)
                            } label: {
                                HStack(spacing: 10) {
                                    InitialsAvatar(name: friend.name, diameter: 32)
                                    Text(friend.name).foregroundStyle(SwarmTheme.textPrimary)
                                }
                            }
                        }
                    }
                } header: {
                    SectionLabel(title: "Friends", count: viewModel.friends.count)
                }
                .listRowBackground(SwarmTheme.panel)

                Section {
                    if viewModel.threads.isEmpty {
                        EmptyStateView(icon: "message", title: "No conversations yet.")
                    } else {
                        ForEach(viewModel.threads) { thread in
                            NavigationLink {
                                ThreadView(accountId: thread.accountId, peerName: thread.name)
                            } label: {
                                HStack(spacing: 10) {
                                    InitialsAvatar(name: thread.name, diameter: 32)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(thread.name).font(.subheadline.bold()).foregroundStyle(SwarmTheme.textPrimary)
                                        if let last = thread.lastMessage {
                                            Text(last).font(.caption).foregroundStyle(SwarmTheme.textMuted).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if let unread = thread.unreadCount, unread > 0 {
                                        Text("\(unread)")
                                            .font(.caption2.bold())
                                            .padding(6)
                                            .background(Circle().fill(SwarmTheme.accent))
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    SectionLabel(title: "Messages", count: viewModel.threads.count)
                }
                .listRowBackground(SwarmTheme.panel)
            }
            .scrollContentBackground(.hidden)
            .background(SwarmTheme.background)
            .navigationTitle("Social")
            .task { await viewModel.loadAll() }
            .refreshable { await viewModel.loadAll() }
            .notificationsBell(notificationsViewModel)
        }
    }
}

#Preview {
    SocialView()
        .environmentObject(NotificationsViewModel())
}
