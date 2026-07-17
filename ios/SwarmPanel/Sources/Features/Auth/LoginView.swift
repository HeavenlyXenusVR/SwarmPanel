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
                    HStack {
                        IconChip(systemName: "person.fill", tint: .blue)
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    HStack {
                        IconChip(systemName: "lock.fill", tint: .gray)
                        SecureField("Password", text: $password)
                    }
                    HStack {
                        IconChip(systemName: "number", tint: .indigo)
                        TextField("Guild ID (owner login only)", text: $guildId)
                            .keyboardType(.numberPad)
                    }
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
                                ProgressView().tint(.white)
                            } else {
                                Text("Log In").bold()
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
