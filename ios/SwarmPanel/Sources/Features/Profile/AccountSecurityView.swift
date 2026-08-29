import SwiftUI

/// Password change, email change, and account verification (webhook or
/// Discord DM, plus code entry) -- mirrors web's ProfilePage.jsx Account +
/// Verification panels, previously entirely unreachable from the app.
struct AccountSecurityView: View {
    @StateObject private var viewModel = AccountSecurityViewModel()

    var body: some View {
        Form {
            Section {
                ChecklistRow(label: viewModel.isVerified ? "Verified" : "Not verified", done: viewModel.isVerified)
                if !viewModel.isVerified && viewModel.verificationPending {
                    Text("Verification pending — enter the code you received below.")
                        .font(.caption)
                        .foregroundStyle(SwarmTheme.textMuted)
                }
            } header: {
                SectionLabel(title: "Status")
            }
            .listRowBackground(SwarmTheme.panel)

            if let error = viewModel.errorMessage {
                Section { ErrorBanner(message: error) }
                    .listRowBackground(SwarmTheme.panel)
            }
            if let status = viewModel.statusMessage {
                Section { Text(status).foregroundStyle(SwarmTheme.ok) }
                    .listRowBackground(SwarmTheme.panel)
            }

            Section {
                TextField("Email", text: $viewModel.email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                Button {
                    Task { await viewModel.changeEmail() }
                } label: {
                    HStack { Spacer(); Text("Update Email").bold(); Spacer() }
                }
                .disabled(viewModel.isSaving)
            } header: {
                SectionLabel(title: "Email")
            }
            .listRowBackground(SwarmTheme.panel)

            Section {
                SecureField("Current Password", text: $viewModel.currentPassword)
                SecureField("New Password (8+ characters)", text: $viewModel.newPassword)
                Button {
                    Task { await viewModel.changePassword() }
                } label: {
                    HStack { Spacer(); Text("Change Password").bold(); Spacer() }
                }
                .disabled(viewModel.isSaving)
            } header: {
                SectionLabel(title: "Password")
            } footer: {
                Text(viewModel.hasPassword ? "" : "No password set yet on this account.")
            }
            .listRowBackground(SwarmTheme.panel)

            Section {
                TextField("Discord Webhook URL", text: $viewModel.verificationWebhookUrl)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button {
                    Task { await viewModel.saveWebhook() }
                } label: {
                    HStack { Spacer(); Text("Save & Send Code").bold(); Spacer() }
                }
                .disabled(viewModel.isSaving)
            } header: {
                SectionLabel(title: "Server Webhook Verification")
            } footer: {
                Text("Proves you own a real Discord server by posting a code to a webhook you control there.")
            }
            .listRowBackground(SwarmTheme.panel)

            Section {
                TextField("Your Discord User ID", text: $viewModel.discordUserId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numberPad)
                Button {
                    Task { await viewModel.saveDiscordUserId() }
                } label: {
                    HStack { Spacer(); Text("Save & Send Code").bold(); Spacer() }
                }
                .disabled(viewModel.isSaving)
            } header: {
                SectionLabel(title: "Discord DM Verification")
            } footer: {
                Text("Sends a code via Discord DM instead — needs the bot to share a server with you.")
            }
            .listRowBackground(SwarmTheme.panel)

            Section {
                TextField("Verification Code", text: $viewModel.verificationCode)
                    .keyboardType(.numberPad)
                Button {
                    Task { await viewModel.submitCode() }
                } label: {
                    HStack { Spacer(); Text("Verify").bold(); Spacer() }
                }
                .disabled(viewModel.isSaving)
                Button("Resend Code") {
                    Task { await viewModel.resendCode() }
                }
                .disabled(viewModel.isSaving)
            } header: {
                SectionLabel(title: "Enter Code")
            }
            .listRowBackground(SwarmTheme.panel)
        }
        .scrollContentBackground(.hidden)
        .background(SwarmTheme.background)
        .navigationTitle("Account Security")
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }
}

private struct ChecklistRow: View {
    let label: String
    let done: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.seal.fill" : "exclamationmark.circle")
                .foregroundStyle(done ? SwarmTheme.ok : SwarmTheme.textMuted)
            Text(label).foregroundStyle(SwarmTheme.textPrimary)
        }
    }
}

#Preview {
    NavigationStack { AccountSecurityView() }
        .environmentObject(ToastCenter())
}
