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

                // Moved up from below Discover — for an admin/moderator, this
                // is the reason they're in this app; burying it at the
                // bottom of a long Form scroll under Account/Appearance/
                // Discover made it easy to miss it was even there.
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

                if appState.isAdmin || appState.isModerator || appState.canGallery {
                    Section {
                        if appState.isAdmin || appState.isModerator {
                            NavigationLink { AuditLogView() } label: { IconRow(icon: "list.bullet.clipboard", tint: .indigo, title: "Audit Log") }
                            NavigationLink { AlertRulesView() } label: { IconRow(icon: "bell.badge", tint: .red, title: "Alert Rules") }
                            NavigationLink { LumisoundAdminView() } label: { IconRow(icon: "waveform", tint: .pink, title: "Lumisound Moderation") }
                        }
                        if appState.canGallery {
                            NavigationLink { GalleryModerationView() } label: { IconRow(icon: "photo.on.rectangle", tint: .teal, title: "Gallery Moderation") }
                        }
                        if appState.isAdmin {
                            NavigationLink { AccountsAdminView() } label: { IconRow(icon: "person.2.badge.gearshape", tint: .blue, title: "Accounts") }
                            NavigationLink { DiagnosticsView() } label: { IconRow(icon: "heart.text.square", tint: .green, title: "Fleet Health") }
                            NavigationLink { FleetTopologyView() } label: { IconRow(icon: "point.3.filled.connected.trianglepath.dotted", tint: .cyan, title: "Fleet Topology") }
                            NavigationLink { ExportsView() } label: { IconRow(icon: "square.and.arrow.down", tint: .orange, title: "Scheduled Exports") }
                            NavigationLink { DatabasesView() } label: { IconRow(icon: "cylinder.split.1x2", tint: .brown, title: "Database Viewer") }
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
                    NavigationLink { InvitesView() } label: { IconRow(icon: "envelope.badge.person.crop", tint: .blue, title: "Invite Bots") }
                    NavigationLink { UsersDirectoryView() } label: { IconRow(icon: "person.3", tint: .purple, title: "Swarm Directory") }
                    NavigationLink { OtherProjectsView() } label: { IconRow(icon: "square.grid.2x2", tint: .pink, title: "My Other Projects") }
                } header: {
                    SectionLabel(title: "Discover")
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
            .navigationTitle("Profile")
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

/// Icon-chip + title row, matching iOS Settings' colored-icon navigation
/// rows — used for every NavigationLink destination on this screen so the
/// list reads as a scannable menu instead of a plain text list.
private struct IconRow: View {
    let icon: String
    let tint: Color
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            IconChip(systemName: icon, tint: tint)
            Text(title).foregroundStyle(SwarmTheme.textPrimary)
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
