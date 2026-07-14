import SwiftUI
import UIKit

struct ProfileView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var notificationsViewModel: NotificationsViewModel
    @EnvironmentObject private var biometricLock: BiometricLock
    @StateObject private var viewModel = ProfileViewModel()
    @State private var selectedIcon = AppIconOption.current

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
                                Button {
                                    UIPasteboard.general.string = guildId
                                    Haptics.success()
                                } label: {
                                    HStack(spacing: 4) {
                                        Text("Guild \(guildId)")
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(SwarmTheme.textMuted)
                                }
                                .buttonStyle(.plain)
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
                    if UIApplication.shared.supportsAlternateIcons {
                        Picker("App Icon", selection: $selectedIcon) {
                            ForEach(AppIconOption.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .onChange(of: selectedIcon) { newValue in
                            UIApplication.shared.setAlternateIconName(newValue.alternateIconName) { error in
                                if error != nil {
                                    Task { @MainActor in selectedIcon = AppIconOption.current }
                                }
                            }
                            Haptics.selection()
                        }
                    }
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

                if appState.isAdmin || appState.isModerator || appState.canGallery {
                    Section {
                        if appState.isAdmin || appState.isModerator {
                            NavigationLink("Audit Log") { AuditLogView() }
                            NavigationLink("Alert Rules") { AlertRulesView() }
                            NavigationLink("Lumisound Moderation") { LumisoundAdminView() }
                        }
                        if appState.canGallery {
                            NavigationLink("Gallery Moderation") { GalleryModerationView() }
                        }
                        if appState.isAdmin {
                            NavigationLink("Accounts") { AccountsAdminView() }
                            NavigationLink("Fleet Health") { DiagnosticsView() }
                            NavigationLink("Scheduled Exports") { ExportsView() }
                        }
                    } header: {
                        SectionLabel(title: "Admin Tools")
                    } footer: {
                        Text("Visible because your account has owner or moderator access on this guild.")
                    }
                    .listRowBackground(SwarmTheme.panel)
                }

                Section {
                    Toggle("Require \(biometricLock.biometryLabel)", isOn: $biometricLock.isEnabled)
                        .tint(SwarmTheme.accent)
                } header: {
                    SectionLabel(title: "Privacy")
                } footer: {
                    Text("Locks SwarmPanel behind \(biometricLock.biometryLabel) whenever it returns from the background.")
                }
                .listRowBackground(SwarmTheme.panel)

                Section {
                    NavigationLink("Server") { ServerSettingsView() }
                } header: {
                    SectionLabel(title: "Advanced")
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
            .refreshable {
                Haptics.light()
                await viewModel.load()
            }
            .notificationsBell(notificationsViewModel)
        }
    }
}

#Preview {
    ProfileView()
        .environmentObject(AppState())
        .environmentObject(AppearanceSettings())
        .environmentObject(NotificationsViewModel())
        .environmentObject(BiometricLock())
}
