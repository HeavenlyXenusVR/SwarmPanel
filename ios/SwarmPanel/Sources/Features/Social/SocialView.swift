import SwiftUI

struct SocialView: View {
    @StateObject private var viewModel = SocialViewModel()

    var body: some View {
        NavigationStack {
            List {
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section("Find People") {
                    HStack {
                        TextField("Search username or display name", text: $viewModel.searchQuery)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await viewModel.search() } }
                        Button("Search") { Task { await viewModel.search() } }
                    }
                    ForEach(viewModel.searchResults) { user in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(user.name)
                                if let server = user.serverName { Text(server).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button("Follow") { Task { await viewModel.follow(user.id) } }
                                .buttonStyle(.borderless)
                            Button("Add") { Task { await viewModel.sendFriendRequest(user.id) } }
                                .buttonStyle(.borderless)
                            NavigationLink {
                                ThreadView(accountId: user.id, peerName: user.name)
                            } label: {
                                Image(systemName: "message")
                            }
                        }
                    }
                }

                if !viewModel.incomingRequests.isEmpty {
                    Section("Friend Requests") {
                        ForEach(viewModel.incomingRequests) { request in
                            HStack {
                                Text(request.name)
                                Spacer()
                                Button("Accept") { Task { await viewModel.respondToRequest(request, action: "accept") } }
                                    .buttonStyle(.borderless)
                                Button("Decline") { Task { await viewModel.respondToRequest(request, action: "decline") } }
                                    .buttonStyle(.borderless)
                                    .tint(.red)
                            }
                        }
                    }
                }

                if !viewModel.outgoingRequests.isEmpty {
                    Section("Sent Requests") {
                        ForEach(viewModel.outgoingRequests) { request in
                            HStack {
                                Text(request.name)
                                Spacer()
                                Text(request.status?.capitalized ?? "Pending").foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Friends") {
                    if viewModel.friends.isEmpty {
                        Text("No friends yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.friends) { friend in
                            NavigationLink {
                                ThreadView(accountId: friend.id, peerName: friend.name)
                            } label: {
                                Text(friend.name)
                            }
                        }
                    }
                }

                Section("Messages") {
                    if viewModel.threads.isEmpty {
                        Text("No conversations yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.threads) { thread in
                            NavigationLink {
                                ThreadView(accountId: thread.accountId, peerName: thread.name)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(thread.name).font(.subheadline.bold())
                                        if let last = thread.lastMessage {
                                            Text(last).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if let unread = thread.unreadCount, unread > 0 {
                                        Text("\(unread)")
                                            .font(.caption2.bold())
                                            .padding(6)
                                            .background(Circle().fill(Color.accentColor))
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Social")
            .task { await viewModel.loadAll() }
            .refreshable { await viewModel.loadAll() }
        }
    }
}

#Preview {
    SocialView()
}
