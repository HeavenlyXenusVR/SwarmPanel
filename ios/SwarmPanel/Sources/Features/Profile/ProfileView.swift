import SwiftUI
import UIKit

struct ProfileView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var appearance: AppearanceSettings
    @EnvironmentObject private var notificationsViewModel: NotificationsViewModel
    @EnvironmentObject private var biometricLock: BiometricLock
    @StateObject private var viewModel = ProfileViewModel()
    @State private var selectedIcon = AppIconOption.current

    private var appVersionString: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(currentAppVersion) (\(build))"
    }

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

                // Kept at the top — for an admin/moderator, this is the
                // reason they're in this app; burying it at the bottom of a
                // long Form scroll made it easy to miss it was even there.
                if appState.isOwner {
                    Section {
                        Toggle(isOn: Binding(
                            get: { appState.isAdmin },
                            set: { newValue in Task { await appState.setAdminMode(newValue) } }
                        )) {
                            IconRow(icon: "shield.lefthalf.filled", tint: .red, title: "Admin Mode")
                        }
                    } footer: {
                        Text("Switches between your normal guild-scoped view and the unrestricted admin view.")
                    }
                    .listRowBackground(SwarmTheme.panel)
                }

                // Admin tools live on their own hub screen (AdminHubView),
                // mirroring the web panel's Admin section — one entry here
                // instead of a nine-row list in the middle of the form.
                if appState.isAdmin || appState.isModerator || appState.canGallery {
                    Section {
                        NavigationLink { AdminHubView() } label: {
                            IconRow(icon: "wrench.and.screwdriver", tint: SwarmTheme.accent, title: "Admin Tools", subtitle: "Monitoring, moderation, and data")
                        }
                    } header: {
                        HStack(spacing: 6) {
                            SwarmPulseRings(color: SwarmTheme.accent, ringCount: 2)
                                .frame(width: 10, height: 10)
                            Text("COMMAND CENTER")
                                .font(.caption.bold())
                                .foregroundStyle(SwarmTheme.accent)
                                .tracking(0.6)
                        }
                    } footer: {
                        Text("Visible because your account has owner or moderator access on this guild.")
                    }
                    .listRowBackground(SwarmTheme.panel)
                }

                Section {
                    TextField("Display Name", text: $viewModel.displayName)
                    TextField("Bio", text: $viewModel.bio, axis: .vertical)
                    Toggle("Public Profile", isOn: $viewModel.isPublic)
                        .tint(SwarmTheme.accent)
                    NavigationLink { AccountSecurityView() } label: {
                        IconRow(icon: "lock.shield", tint: .red, title: "Account Security")
                    }
                } header: {
                    SectionLabel(title: "Account")
                }
                .listRowBackground(SwarmTheme.panel)

                Section {
                    ChecklistRow(label: "Account verified", done: viewModel.isVerified)
                    ChecklistRow(label: "Display name set", done: !viewModel.displayName.isEmpty)
                    ChecklistRow(label: "Avatar set", done: viewModel.hasAvatar)
                    ChecklistRow(label: "Bio written", done: !viewModel.bio.isEmpty)
                    ChecklistRow(label: "Profile is public", done: viewModel.isPublic)
                } header: {
                    SectionLabel(title: "Getting Started")
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

                Section {
                    HStack {
                        IconChip(systemName: "faceid", tint: .green)
                        Toggle("Require \(biometricLock.biometryLabel)", isOn: $biometricLock.isEnabled)
                    }
                    .tint(SwarmTheme.accent)
                } header: {
                    SectionLabel(title: "Privacy")
                } footer: {
                    Text("Locks SwarmPanel behind \(biometricLock.biometryLabel) whenever it returns from the background.")
                }
                .listRowBackground(SwarmTheme.panel)

                Section {
                    NavigationLink { ServerSettingsView() } label: { IconRow(icon: "server.rack", tint: .gray, title: "Server") }
                } header: {
                    SectionLabel(title: "Advanced")
                }
                .listRowBackground(SwarmTheme.panel)

                Section {
                    NavigationLink { WhatsNewView() } label: { IconRow(icon: "sparkles", tint: .yellow, title: "What's New") }
                    NavigationLink { OtherProjectsView() } label: { IconRow(icon: "square.grid.2x2", tint: .pink, title: "Other Projects") }
                    LabeledContent("Version", value: appVersionString)
                } header: {
                    SectionLabel(title: "About")
                }
                .listRowBackground(SwarmTheme.panel)

                Section {
                    Button("Log Out", role: .destructive) { appState.logout() }
                }
                .listRowBackground(SwarmTheme.panel)
            }
            .scrollContentBackground(.hidden)
            .background(SwarmTheme.background)
            .navigationTitle("Account")
            .task { await viewModel.load() }
            .refreshable {
                Haptics.light()
                await viewModel.load()
                await appState.refreshSession()
            }
            .refreshOnForeground {
                await viewModel.load()
                await appState.refreshSession()
            }
            .notificationsBell(notificationsViewModel)
        }
    }
}

/// Read-only checklist row for the Getting Started section -- mirrors the
/// web panel's check-row (CSS existed there too, also newly wired this
/// round).
private struct ChecklistRow: View {
    let label: String
    let done: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? SwarmTheme.ok : SwarmTheme.textMuted)
            Text(label).foregroundStyle(SwarmTheme.textPrimary)
        }
    }
}

#Preview {
    ProfileView()
        .environmentObject(AppState())
        .environmentObject(AppearanceSettings())
        .environmentObject(NotificationsViewModel())
        .environmentObject(BiometricLock())
        .environmentObject(ToastCenter())
}
