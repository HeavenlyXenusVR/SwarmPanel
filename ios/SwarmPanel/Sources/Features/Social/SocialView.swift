import SwiftUI

struct SocialView: View {
    @EnvironmentObject private var notificationsViewModel: NotificationsViewModel
    @StateObject private var viewModel = SocialViewModel()
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                if let error = viewModel.errorMessage {
                    Section { ErrorBanner(message: error) }
                        .listRowBackground(SwarmTheme.panel)
                }

                Section {
                    HStack {
                        TextField("Search username or display name", text: $viewModel.searchQuery)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($isSearchFocused)
                            .onSubmit { Task { await viewModel.search() } }
                        Button { Task { await viewModel.search() } } label: {
                            Image(systemName: "magnifyingglass.circle.fill")
                                .font(.title2)
                                .foregroundStyle(SwarmTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(viewModel.searchResults) { user in
                        HStack(spacing: 10) {
                            // Scoped to just the avatar/name (not the whole
                            // row) so Follow/Friend/Message stay independent
                            // tap targets, same pattern the message-icon
                            // NavigationLink below already relies on.
                            NavigationLink { PublicProfileView(accountId: user.id) } label: {
                                HStack(spacing: 10) {
                                    InitialsAvatar(name: user.name, diameter: 32)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(user.name).foregroundStyle(SwarmTheme.textPrimary)
                                        if let server = user.serverName {
                                            Text(server).font(.caption).foregroundStyle(SwarmTheme.textMuted)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            SocialActionButton(icon: "person.badge.plus", tint: .blue) {
                                Task { await viewModel.follow(user.id) }
                            }
                            SocialActionButton(icon: "person.2.fill", tint: .purple) {
                                Task { await viewModel.sendFriendRequest(user.id) }
                            }
                            NavigationLink {
                                ThreadView(accountId: user.id, peerName: user.name)
                            } label: {
                                Image(systemName: "message.fill")
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                    .frame(width: 30, height: 30)
                                    .background(SwarmTheme.ok.gradient, in: Circle())
                            }
                        }
                    }
                } header: {
                    SectionLabel(title: "Find People")
                }
                .listRowBackground(SwarmTheme.panel)
                .id("findPeople")

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
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await viewModel.respondToRequest(request, action: "decline") }
                                } label: {
                                    Label("Decline", systemImage: "xmark")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    Task { await viewModel.respondToRequest(request, action: "accept") }
                                } label: {
                                    Label("Accept", systemImage: "checkmark")
                                }
                                .tint(SwarmTheme.ok)
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
                                Button("Cancel") { Task { await viewModel.respondToRequest(request, action: "cancel") } }
                                    .buttonStyle(.borderless)
                                    .tint(SwarmTheme.danger)
                                    .font(.caption)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await viewModel.respondToRequest(request, action: "cancel") }
                                } label: {
                                    Label("Cancel", systemImage: "xmark")
                                }
                            }
                        }
                    } header: {
                        SectionLabel(title: "Sent Requests")
                    }
                    .listRowBackground(SwarmTheme.panel)
                }

                Section {
                    if viewModel.friends.isEmpty {
                        VStack(spacing: 10) {
                            EmptyStateView(icon: "person.2.slash", title: "No friends yet.")
                            Button("Find People") {
                                withAnimation { proxy.scrollTo("findPeople", anchor: .top) }
                                isSearchFocused = true
                            }
                            .buttonStyle(.bordered)
                            .tint(SwarmTheme.accent)
                        }
                        .frame(maxWidth: .infinity)
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
            .refreshable {
                Haptics.light()
                await viewModel.loadAll()
            }
            .refreshOnForeground { await viewModel.loadAll() }
            .onDisappear { viewModel.stopWatching() }
            .notificationsBell(notificationsViewModel)
            }
        }
    }
}

private struct SocialActionButton: View {
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SocialView()
        .environmentObject(NotificationsViewModel())
        .environmentObject(ToastCenter())
}
