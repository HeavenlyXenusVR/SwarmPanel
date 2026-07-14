import SwiftUI
import UIKit

struct NotificationsView: View {
    @ObservedObject var viewModel: NotificationsViewModel
    @EnvironmentObject private var toastCenter: ToastCenter
    @Environment(\.dismiss) private var dismiss
    @State private var searchQuery = ""

    private var filteredNotifications: [PanelNotification] {
        guard !searchQuery.isEmpty else { return viewModel.notifications }
        let needle = searchQuery.lowercased()
        return viewModel.notifications.filter {
            $0.title.lowercased().contains(needle) || ($0.body ?? "").lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = viewModel.errorMessage {
                    Section { ErrorBanner(message: error) }
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
                } else if filteredNotifications.isEmpty {
                    Section {
                        EmptyStateView(icon: "magnifyingglass", title: "No notifications match \"\(searchQuery)\".")
                    }
                    .listRowBackground(SwarmTheme.panel)
                } else {
                    Section {
                        ForEach(filteredNotifications) { notification in
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
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = [notification.title, notification.body].compactMap { $0 }.joined(separator: "\n")
                                    Haptics.success()
                                    toastCenter.success("Copied")
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
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
            .searchable(text: $searchQuery, prompt: "Search notifications")
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
            .refreshable {
                Haptics.light()
                await viewModel.loadNotifications()
            }
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
        .environmentObject(ToastCenter())
}
