import SwiftUI

struct NotificationsView: View {
    @ObservedObject var viewModel: NotificationsViewModel

    var body: some View {
        NavigationStack {
            List {
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if viewModel.notifications.isEmpty && !viewModel.isLoading {
                    Text("You're all caught up.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.notifications) { notification in
                        Button {
                            Task { await viewModel.markRead(notification) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(notification.title)
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.primary)
                                    if notification.isUnread {
                                        Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                                    }
                                }
                                if let body = notification.body, !body.isEmpty {
                                    Text(body)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Notifications")
            .toolbar {
                if viewModel.unreadCount > 0 {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Mark All Read") { Task { await viewModel.markAllRead() } }
                    }
                }
            }
            .task { await viewModel.loadNotifications() }
            .refreshable { await viewModel.loadNotifications() }
        }
    }
}

#Preview {
    NotificationsView(viewModel: NotificationsViewModel())
}
