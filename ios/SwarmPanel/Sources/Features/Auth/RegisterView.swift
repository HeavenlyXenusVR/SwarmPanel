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
    @State private var isSubmitting = false

    private var canSubmit: Bool {
        !username.isEmpty && !guildId.isEmpty && password.count >= 8 && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Discord Guild ID", text: $guildId)
                        .keyboardType(.numberPad)
                    SecureField("Password (min. 8 characters)", text: $password)
                    TextField("Email (optional)", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                }

                Section {
                    TextField("Discord webhook URL", text: $verificationWebhookUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Guild ownership proof")
                } footer: {
                    Text("Create a webhook in your Discord server (Server Settings → Integrations → Webhooks) and paste its URL here — SwarmPanel uses it to confirm you control this guild before creating the account.")
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
                                ProgressView()
                            } else {
                                Text("Create Account").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
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
            verificationWebhookUrl: verificationWebhookUrl
        )
        if appState.isAuthenticated { dismiss() }
    }
}

#Preview {
    RegisterView()
        .environmentObject(AppState())
}
