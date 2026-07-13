import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var appState: AppState
    @State private var username = ""
    @State private var password = ""
    @State private var guildId = ""
    @State private var isSubmitting = false
    @State private var showRegister = false

    private var canSubmit: Bool {
        !username.isEmpty && !password.isEmpty && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    TextField("Guild ID (owner login only)", text: $guildId)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("Guild members can leave Guild ID blank — it's only needed for the site-owner admin login.")
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
                                Text("Log In").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle("SwarmPanel")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Register") { showRegister = true }
                }
            }
            .sheet(isPresented: $showRegister) {
                RegisterView()
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        await appState.login(username: username, password: password, guildId: guildId)
    }
}

#Preview {
    LoginView()
        .environmentObject(AppState())
}
