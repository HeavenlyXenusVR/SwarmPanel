import SwiftUI

struct AccountsAdminView: View {
    @StateObject private var viewModel = AccountsAdminViewModel()
    @State private var resetPasswordTarget: SwarmAccountSummary?
    @State private var newPassword = ""
    @State private var deleteTarget: SwarmAccountSummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PanelCard {
                    HStack {
                        IconChip(systemName: "magnifyingglass", tint: .gray)
                        TextField("Search accounts", text: $viewModel.query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await viewModel.load() } }
                    }
                }
                .padding(.horizontal)

                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error).padding(.horizontal)
                }
                if let status = viewModel.statusMessage {
                    Text(status).foregroundStyle(SwarmTheme.ok).padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: "Accounts", count: viewModel.accounts.count)
                    if viewModel.accounts.isEmpty {
                        PanelCard { EmptyStateView(icon: "person.crop.circle.badge.questionmark", title: "No accounts found.") }
                    } else {
                        PanelCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(viewModel.accounts.enumerated()), id: \.element.id) { index, account in
                                    if index > 0 { Divider().overlay(SwarmTheme.line) }
                                    AccountRow(
                                        account: account,
                                        viewModel: viewModel,
                                        onResetPassword: {
                                            resetPasswordTarget = account
                                            newPassword = ""
                                        },
                                        onDelete: { deleteTarget = account }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(SwarmTheme.background)
        .navigationTitle("Accounts")
        .task { await viewModel.load() }
        .refreshable {
            Haptics.light()
            await viewModel.load()
        }
        .refreshOnForeground { await viewModel.load() }
        .alert("Reset Password", isPresented: Binding(get: { resetPasswordTarget != nil }, set: { if !$0 { resetPasswordTarget = nil } })) {
            SecureField("New password", text: $newPassword)
            Button("Cancel", role: .cancel) { resetPasswordTarget = nil }
            Button("Reset") {
                if let target = resetPasswordTarget, newPassword.count >= 8 {
                    Task { await viewModel.resetPassword(target, newPassword: newPassword) }
                }
                resetPasswordTarget = nil
            }
        } message: {
            Text("Enter a new password (min. 8 characters) for \(resetPasswordTarget?.username ?? "this account").")
        }
        .alert("Delete Account", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                if let target = deleteTarget { Task { await viewModel.delete(target) } }
                deleteTarget = nil
            }
        } message: {
            Text("Permanently delete \(deleteTarget?.username ?? "this account")? This cannot be undone.")
        }
    }
}

private struct AccountRow: View {
    let account: SwarmAccountSummary
    @ObservedObject var viewModel: AccountsAdminViewModel
    let onResetPassword: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                InitialsAvatar(name: account.name, diameter: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).font(.subheadline.bold()).foregroundStyle(SwarmTheme.textPrimary)
                    if let guildId = account.guildId {
                        Text("Guild \(guildId)").font(.caption2).foregroundStyle(SwarmTheme.textMuted)
                    }
                }
                Spacer()
                if account.isModerator {
                    StatusPill(text: "Moderator", tone: .soft)
                }
                StatusPill(text: account.verificationVerified == true ? "Verified" : "Unverified", tone: account.verificationVerified == true ? .live : .off)
            }
            HStack(spacing: 14) {
                Button(account.verificationVerified == true ? "Unverify" : "Verify") {
                    Task { await viewModel.toggleVerified(account) }
                }
                Button(account.isModerator ? "Revoke Mod" : "Make Mod") {
                    Task { await viewModel.toggleModerator(account) }
                }
                Button("Reset Password", action: onResetPassword)
                Button("Delete", role: .destructive, action: onDelete)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .tint(SwarmTheme.accent)
        }
        .padding(14)
    }
}

#Preview {
    NavigationStack { AccountsAdminView() }
        .environmentObject(ToastCenter())
}
