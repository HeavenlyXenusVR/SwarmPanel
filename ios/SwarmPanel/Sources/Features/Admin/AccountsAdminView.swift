import SwiftUI

struct AccountsAdminView: View {
    @StateObject private var viewModel = AccountsAdminViewModel()
    @State private var resetPasswordTarget: SwarmAccountSummary?
    @State private var newPassword = ""
    @State private var deleteTarget: SwarmAccountSummary?
    @State private var showBulkDeleteConfirm = false

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
                    if !viewModel.accounts.isEmpty {
                        let verifiedCount = viewModel.accounts.filter { $0.verificationVerified == true }.count
                        let modCount = viewModel.accounts.filter(\.isModerator).count
                        Text("\(verifiedCount) verified, \(viewModel.accounts.count - verifiedCount) unverified, \(modCount) moderator\(modCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(SwarmTheme.textMuted)
                    }
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
            // Room for the bulk-action bar so the last row isn't hidden behind it.
            .padding(.bottom, viewModel.isSelecting && !viewModel.selectedIds.isEmpty ? 64 : 0)
        }
        .background(SwarmTheme.background)
        .navigationTitle("Accounts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(viewModel.isSelecting ? "Done" : "Select") {
                    if viewModel.isSelecting { viewModel.exitSelectionMode() } else { viewModel.isSelecting = true }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if viewModel.isSelecting && !viewModel.selectedIds.isEmpty {
                BulkActionBar(
                    count: viewModel.selectedIds.count,
                    isWorking: viewModel.isBulkWorking,
                    onVerify: { Task { await viewModel.bulkVerify(true) } },
                    onUnverify: { Task { await viewModel.bulkVerify(false) } },
                    onDelete: { showBulkDeleteConfirm = true }
                )
            }
        }
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
        .confirmationDialog(
            "Delete \(viewModel.selectedIds.count) account(s)?",
            isPresented: $showBulkDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(viewModel.selectedIds.count) Account(s)", role: .destructive) {
                Task { await viewModel.bulkDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every selected account. This cannot be undone.")
        }
    }
}

private struct BulkActionBar: View {
    let count: Int
    let isWorking: Bool
    let onVerify: () -> Void
    let onUnverify: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(count) selected")
                .font(.caption.bold())
                .foregroundStyle(SwarmTheme.textMuted)
            Spacer()
            if isWorking {
                ProgressView().tint(SwarmTheme.accent)
            } else {
                Button(action: onVerify) { Image(systemName: "checkmark.seal") }
                Button(action: onUnverify) { Image(systemName: "xmark.seal") }
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
            }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct AccountRow: View {
    let account: SwarmAccountSummary
    @ObservedObject var viewModel: AccountsAdminViewModel
    let onResetPassword: () -> Void
    let onDelete: () -> Void

    private var isSelected: Bool { viewModel.selectedIds.contains(account.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if viewModel.isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? SwarmTheme.accent : SwarmTheme.textMuted)
                }
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
            if !viewModel.isSelecting {
                HStack(spacing: 14) {
                    Button(account.verificationVerified == true ? "Unverify" : "Verify") {
                        Task { await viewModel.toggleVerified(account) }
                    }
                    Button(account.isModerator ? "Revoke Mod" : "Make Mod") {
                        Task { await viewModel.toggleModerator(account) }
                    }
                    if account.verificationVerified != true {
                        Button("Resend Code") {
                            Task { await viewModel.resendVerification(account) }
                        }
                    }
                    Button("Reset Password", action: onResetPassword)
                    Button("Delete", role: .destructive, action: onDelete)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .tint(SwarmTheme.accent)
            }
        }
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture {
            guard viewModel.isSelecting else { return }
            viewModel.toggleSelection(account.id)
        }
    }
}

#Preview {
    NavigationStack { AccountsAdminView() }
        .environmentObject(ToastCenter())
}
