import SwiftUI

/// Toolbar bell + unread badge, opening Notifications as a sheet. Used
/// instead of a 6th tab: iOS auto-folds a TabView's overflow into a plain
/// unstyled "More" list once there are more than 5 items, which silently
/// buried two of six tabs behind an extra tap. This matches the original
/// intent (a nav-bar accessory, like the web bell in Shell.jsx) and keeps
/// every top-level screen directly reachable from the tab bar.
private struct NotificationsBellModifier: ViewModifier {
    @ObservedObject var viewModel: NotificationsViewModel
    @State private var showSheet = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSheet = true
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "bell")
                            if viewModel.unreadCount > 0 {
                                Text(viewModel.unreadCount > 99 ? "99+" : "\(viewModel.unreadCount)")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(3)
                                    .background(SwarmTheme.danger, in: Circle())
                                    .foregroundStyle(.white)
                                    .offset(x: 12, y: -8)
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showSheet) {
                NotificationsView(viewModel: viewModel)
            }
    }
}

extension View {
    func notificationsBell(_ viewModel: NotificationsViewModel) -> some View {
        modifier(NotificationsBellModifier(viewModel: viewModel))
    }
}
