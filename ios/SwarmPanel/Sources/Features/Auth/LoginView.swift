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

    @FocusState private var focused: Field?
    private enum Field { case username, password, guild }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    VStack(spacing: 14) {
                        ResonanceEmblem(size: 128)
                        Text("SwarmPanel")
                            .font(Res.display(38))
                            .foregroundStyle(Res.ink)
                        Text("Thirteen bots, one console. Sign in to tune in.")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(Res.mist)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 36)

                    VStack(spacing: 0) {
                        field(icon: "person.fill", tint: .blue) {
                            TextField("Username", text: $username)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focused, equals: .username)
                                .submitLabel(.next)
                                .onSubmit { focused = .password }
                        }
                        Divider().overlay(Res.hairline).padding(.leading, 56)
                        field(icon: "lock.fill", tint: .gray) {
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                                .focused($focused, equals: .password)
                                .submitLabel(.go)
                                .onSubmit { if canSubmit { Task { await submit() } } }
                        }
                        Divider().overlay(Res.hairline).padding(.leading, 56)
                        field(icon: "number", tint: .indigo) {
                            TextField("Guild ID (owner login only)", text: $guildId)
                                .keyboardType(.numberPad)
                                .focused($focused, equals: .guild)
                        }
                    }
                    .resGlass(radius: Res.Radius.card)

                    Text("Guild members can leave Guild ID blank — it's only needed for the site-owner admin login.")
                        .font(.caption)
                        .foregroundStyle(Res.mist)
                        .multilineTextAlignment(.center)

                    if let error = appState.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(Res.danger)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .resGlass(edge: Res.danger)
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView().tint(.black)
                        } else {
                            Text("Sign In")
                        }
                    }
                    .buttonStyle(ResPrimaryButtonStyle())
                    .disabled(!canSubmit)

                    Button("New here? Register an account") { showRegister = true }
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .resonanceScreen()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink { ServerSettingsView() } label: {
                        Image(systemName: "server.rack")
                    }
                    .accessibilityLabel("Server settings")
                }
            }
            .sheet(isPresented: $showRegister) {
                RegisterView()
            }
        }
    }

    private func field<Content: View>(icon: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            IconChip(systemName: icon, tint: tint, diameter: 30)
            content()
                .font(.system(.body, design: .rounded))
                .foregroundStyle(Res.ink)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
