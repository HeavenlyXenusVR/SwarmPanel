import SwiftUI

struct NotificationsView: View {
    @ObservedObject var viewModel: NotificationsViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = viewModel.errorMessage {
                        Text(error).foregroundStyle(SwarmTheme.danger).padding(.horizontal)
                    }
                    if viewModel.notifications.isEmpty && !viewModel.isLoading {
                        PanelCard {
                            Text("You're all caught up.").foregroundStyle(SwarmTheme.textMuted)
                        }
                        .padding(.horizontal)
                    } else {
                        PanelCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(viewModel.notifications.enumerated()), id: \.element.id) { index, notification in
                                    if index > 0 { Divider().overlay(SwarmTheme.line) }
                                    Button {
                                        Task { await viewModel.markRead(notification) }
                                    } label: {
                                        NotificationRow(notification: notification)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .background(SwarmTheme.background)
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
