import SwiftUI

/// Mirrors the web registration flow (app/routers/session.py's
/// /api/session/register): a guild must prove ownership via a Discord
/// webhook URL before an account can be created for it.
struct RegisterView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var guildId = ""
    @State private var password = ""
    @State private var email = ""
    @State private var verificationWebhookUrl = ""
    @State private var discordUserId = ""
    @State private var proofMethod: ProofMethod = .webhook
    @State private var isSubmitting = false

    private enum ProofMethod: String, CaseIterable, Identifiable {
        case webhook = "Server Webhook"
        case discord = "Discord DM"
        var id: String { rawValue }
    }

    private var canSubmit: Bool {
        !username.isEmpty && !guildId.isEmpty && password.count >= 8 && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    HStack {
                        IconChip(systemName: "person.fill", tint: .blue)
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    HStack {
                        IconChip(systemName: "number", tint: .indigo)
                        TextField("Discord Guild ID", text: $guildId)
                            .keyboardType(.numberPad)
                    }
                    HStack {
                        IconChip(systemName: "lock.fill", tint: .gray)
                        SecureField("Password (min. 8 characters)", text: $password)
                    }
                    HStack {
                        IconChip(systemName: "envelope.fill", tint: .teal)
                        TextField("Email (optional)", text: $email)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                    }
                }

                Section {
                    Picker("Proof method", selection: $proofMethod) {
                        ForEach(ProofMethod.allCases) { method in Text(method.rawValue).tag(method) }
                    }
                    .pickerStyle(.segmented)
                    if proofMethod == .webhook {
                        HStack {
                            IconChip(systemName: "link", tint: .purple)
                            TextField("Discord webhook URL", text: $verificationWebhookUrl)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    } else {
                        HStack {
                            IconChip(systemName: "at", tint: .purple)
                            TextField("Your Discord User ID", text: $discordUserId)
                                .keyboardType(.numberPad)
                        }
                    }
                } header: {
                    Text("Guild ownership proof")
                } footer: {
                    Text(proofMethod == .webhook
                        ? "Create a webhook in your Discord server (Server Settings → Integrations → Webhooks) and paste its URL here — SwarmPanel uses it to confirm you control this guild before creating the account."
                        : "SwarmPanel's verification bot DMs a code straight to this Discord account. Enable Developer Mode (Settings → Advanced), then right-click your name → Copy User ID. The bot can only DM accounts that share a server with it.")
                }

                if let error = appState.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView().tint(.white)
                            } else {
                                Text("Create Account").bold()
                            }
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Rectangle().fill(SwarmTheme.accent.gradient))
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.5)
                }
            }
            .navigationTitle("Register")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        await appState.register(
            username: username,
            guildId: guildId,
            password: password,
            email: email,
            verificationWebhookUrl: proofMethod == .webhook ? verificationWebhookUrl : "",
            discordUserId: proofMethod == .discord ? discordUserId : ""
        )
        if appState.isAuthenticated { dismiss() }
    }
}

#Preview {
    RegisterView()
        .environmentObject(AppState())
}
