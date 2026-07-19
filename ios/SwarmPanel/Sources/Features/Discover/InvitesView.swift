import SwiftUI
import UIKit

struct InvitesView: View {
    @StateObject private var viewModel = InvitesViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error).padding(.horizontal)
                }

                if viewModel.inviteBots.isEmpty && !viewModel.isLoading {
                    PanelCard { EmptyStateView(icon: "envelope.badge.person.crop", title: "No inviteable bots yet.") }
                        .padding(.horizontal)
                } else {
                    ForEach(viewModel.inviteBots) { bot in
                        InviteBotCard(bot: bot)
                            .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
        .background(SwarmTheme.background)
        .navigationTitle("Invite Bots")
        .task { await viewModel.load() }
        .refreshable {
            Haptics.light()
            await viewModel.load()
        }
        .refreshOnForeground { await viewModel.load() }
    }
}

private struct InviteBotCard: View {
    let bot: InviteBot

    private var accentColor: Color { Color(hex: bot.accent ?? "") ?? SwarmTheme.accent }

    private var status: (label: String, tone: StatusTone) {
        guard bot.tokenConfigured == true else { return ("Token Missing", .danger) }
        return bot.connectedToSessionGuild == true ? ("Ready Here", .live) : ("Ready", .soft)
    }

    var body: some View {
        PanelCard {
            HStack(spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.displayName ?? bot.key).font(.headline).foregroundStyle(SwarmTheme.textPrimary)
                    Text(bot.identityName ?? (bot.tokenConfigured == true ? "Discord application ready" : "Discord token missing"))
                        .font(.caption)
                        .foregroundStyle(SwarmTheme.textMuted)
                }
                Spacer()
                StatusPill(text: status.label, tone: status.tone)
            }
            if let summary = bot.capabilitySummary {
                Text(summary).font(.subheadline).foregroundStyle(SwarmTheme.textMuted)
            }
            if let permissions = bot.permissions, !permissions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(permissions.prefix(6), id: \.self) { permission in
                            Text(permission)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(SwarmTheme.panel2, in: Capsule())
                                .foregroundStyle(SwarmTheme.textMuted)
                        }
                    }
                }
            }
            if let inviteUrlString = bot.inviteUrl, let url = URL(string: inviteUrlString) {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    HStack {
                        Spacer()
                        Label("Invite", systemImage: "bolt.fill").bold()
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 4)
                }
                .background(accentColor.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Text("Invite unavailable").font(.caption).foregroundStyle(SwarmTheme.textMuted)
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let iconUrlString = bot.iconUrl, let url = URL(string: iconUrlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    InitialsAvatar(name: bot.label, diameter: 44)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
        } else {
            InitialsAvatar(name: bot.label, diameter: 44)
        }
    }
}

#Preview {
    NavigationStack { InvitesView() }
        .environmentObject(ToastCenter())
}
