import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var appearance: AppearanceSettings
    @StateObject private var viewModel = ProfileViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        InitialsAvatar(name: appState.username.isEmpty ? "?" : appState.username, diameter: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.username)
                                .font(.title3.bold())
                                .foregroundStyle(SwarmTheme.textPrimary)
                            if let guildId = appState.guildId {
                                Text("Guild \(guildId)")
                                    .font(.caption)
                                    .foregroundStyle(SwarmTheme.textMuted)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(SwarmTheme.panel)

                Section {
                    TextField("Display Name", text: $viewModel.displayName)
                    TextField("Bio", text: $viewModel.bio, axis: .vertical)
                    Toggle("Public Profile", isOn: $viewModel.isPublic)
                        .tint(SwarmTheme.accent)
                } header: {
                    SectionLabel(title: "Account")
                }
                .listRowBackground(SwarmTheme.panel)

                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(SwarmTheme.danger) }
                        .listRowBackground(SwarmTheme.panel)
                }
                if let status = viewModel.statusMessage {
                    Section { Text(status).foregroundStyle(SwarmTheme.ok) }
                        .listRowBackground(SwarmTheme.panel)
                }

                Section {
                    Picker("Theme", selection: $appearance.colorSchemeOption) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    // Applies instantly via appearance.accentColorHex (read by
                    // .tint() at the app root) — no network call per drag tick.
                    // The chosen color is only pushed to the account's
                    // theme_accent field when Save Profile below is tapped.
                    ColorPicker(
                        "Accent Color",
                        selection: Binding(
                            get: { appearance.accentColor },
                            set: { newColor in
                                guard let hex = newColor.toHex() else { return }
                                appearance.accentColorHex = hex
                            }
                        )
                    )
                } header: {
                    SectionLabel(title: "Appearance")
                } footer: {
                    Text("Theme and accent apply instantly on this device. Accent also syncs to your account when you tap Save Profile, so it's consistent on the web panel too.")
                }
                .listRowBackground(SwarmTheme.panel)

                Section {
                    Button {
                        Task { await viewModel.save(themeAccentHex: appearance.accentColorHex) }
                    } label: {
                        HStack {
                            Spacer()
                            if viewModel.isSaving { ProgressView() } else { Text("Save Profile").bold() }
                            Spacer()
                        }
                    }
                    .disabled(viewModel.isSaving)
                    .tint(SwarmTheme.accent)
                }
                .listRowBackground(SwarmTheme.panel)

                Section {
                    Button("Log Out", role: .destructive) { appState.logout() }
                }
                .listRowBackground(SwarmTheme.panel)
            }
            .scrollContentBackground(.hidden)
            .background(SwarmTheme.background)
            .navigationTitle("Profile")
            .task { await viewModel.load() }
        }
    }
}

#Preview {
    ProfileView()
        .environmentObject(AppState())
        .environmentObject(AppearanceSettings())
}
