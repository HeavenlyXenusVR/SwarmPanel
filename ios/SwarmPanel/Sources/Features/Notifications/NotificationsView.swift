import SwiftUI

struct NotificationsView: View {
    @ObservedObject var viewModel: NotificationsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(SwarmTheme.danger) }
                        .listRowBackground(SwarmTheme.panel)
                }
                if viewModel.notifications.isEmpty && viewModel.isLoading {
                    Section { SkeletonList(rowCount: 4) }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                } else if viewModel.notifications.isEmpty {
                    Section {
                        EmptyStateView(icon: "checkmark.circle", title: "You're all caught up.")
                    }
                    .listRowBackground(SwarmTheme.panel)
                } else {
                    Section {
                        ForEach(viewModel.notifications) { notification in
                            Button {
                                Task { await viewModel.markRead(notification) }
                            } label: {
                                NotificationRow(notification: notification)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                if notification.isUnread {
                                    Button {
                                        Task { await viewModel.markRead(notification) }
                                    } label: {
                                        Label("Mark Read", systemImage: "checkmark")
                                    }
                                    .tint(SwarmTheme.accent)
                                }
                            }
                        }
                    }
                    .listRowBackground(SwarmTheme.panel)
                }
            }
            .scrollContentBackground(.hidden)
            .background(SwarmTheme.background)
            .navigationTitle("Notifications")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
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

private struct NotificationRow: View {
    let notification: PanelNotification

    private var icon: String {
        switch notification.kind {
        case "follow": return "person.badge.plus"
        case "friend_request": return "person.2"
        case "friend_accept": return "person.2.fill"
        case "message": return "message.fill"
        default: return "bell.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(SwarmTheme.accent)
                .frame(width: 28, height: 28)
                .background(SwarmTheme.accent.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(notification.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(SwarmTheme.textPrimary)
                if let body = notification.body, !body.isEmpty {
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(SwarmTheme.textMuted)
                        .lineLimit(2)
                }
            }
            Spacer()
            if notification.isUnread {
                Circle().fill(SwarmTheme.accent).frame(width: 8, height: 8)
            }
        }
        .padding(14)
    }
}

#Preview {
    NotificationsView(viewModel: NotificationsViewModel())
}
