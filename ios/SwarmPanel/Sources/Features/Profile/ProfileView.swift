import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var appearance: AppearanceSettings
    @StateObject private var viewModel = ProfileViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Username", value: appState.username)
                    if let guildId = appState.guildId {
                        LabeledContent("Guild", value: guildId)
                    }
                    TextField("Display Name", text: $viewModel.displayName)
                    TextField("Bio", text: $viewModel.bio, axis: .vertical)
                    Toggle("Public Profile", isOn: $viewModel.isPublic)
                }

                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if let status = viewModel.statusMessage {
                    Section { Text(status).foregroundStyle(.green) }
                }

                Section {
                    Button {
                        Task { await viewModel.save() }
                    } label: {
                        HStack {
                            Spacer()
                            if viewModel.isSaving { ProgressView() } else { Text("Save Profile").bold() }
                            Spacer()
                        }
                    }
                    .disabled(viewModel.isSaving)
                }

                Section("Appearance") {
                    Picker("Theme", selection: $appearance.colorSchemeOption) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    ColorPicker(
                        "Accent Color",
                        selection: Binding(
                            get: { appearance.accentColor },
                            set: { newColor in
                                guard let hex = newColor.toHex() else { return }
                                appearance.accentColorHex = hex
                                Task { await viewModel.save(themeAccentHex: hex) }
                            }
                        )
                    )
                }

                Section {
                    Button("Log Out", role: .destructive) { appState.logout() }
                }
            }
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
