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

    private var roleLabel: String {
        if appState.isOwner { return appState.isAdmin ? "Owner · admin mode" : "Owner" }
        if appState.isModerator { return "Moderator" }
        return appState.role.isEmpty ? "Member" : appState.role.capitalized
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    IdentityCard(
                        name: viewModel.displayName.isEmpty ? appState.username : viewModel.displayName,
                        username: appState.username,
                        guildId: appState.guildId,
                        role: roleLabel,
                        isPublic: viewModel.isPublic
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }

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
                    .listRowBackground(ResRowBackground())
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
                    .listRowBackground(ResRowBackground())
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
                .listRowBackground(ResRowBackground())

                Section {
                    ChecklistRow(label: "Account verified", done: viewModel.isVerified)
                    ChecklistRow(label: "Display name set", done: !viewModel.displayName.isEmpty)
                    ChecklistRow(label: "Avatar set", done: viewModel.hasAvatar)
                    ChecklistRow(label: "Bio written", done: !viewModel.bio.isEmpty)
                    ChecklistRow(label: "Profile is public", done: viewModel.isPublic)
                } header: {
                    SectionLabel(title: "Getting Started")
                }
                .listRowBackground(ResRowBackground())

                if let error = viewModel.errorMessage {
                    Section { ErrorBanner(message: error) }
                        .listRowBackground(ResRowBackground())
                }
                if let status = viewModel.statusMessage {
                    Section { Text(status).foregroundStyle(SwarmTheme.ok) }
                        .listRowBackground(ResRowBackground())
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
                .listRowBackground(ResRowBackground())

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
                .listRowBackground(ResRowBackground())

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
                .listRowBackground(ResRowBackground())

                Section {
                    NavigationLink { ServerSettingsView() } label: { IconRow(icon: "server.rack", tint: .gray, title: "Server") }
                } header: {
                    SectionLabel(title: "Advanced")
                }
                .listRowBackground(ResRowBackground())

                Section {
                    NavigationLink { WhatsNewView() } label: { IconRow(icon: "sparkles", tint: .yellow, title: "What's New") }
                    NavigationLink { OtherProjectsView() } label: { IconRow(icon: "square.grid.2x2", tint: .pink, title: "Other Projects") }
                    LabeledContent("Version", value: appVersionString)
                } header: {
                    SectionLabel(title: "About")
                }
                .listRowBackground(ResRowBackground())

                Section {
                    Button("Log Out", role: .destructive) { appState.logout() }
                }
                .listRowBackground(ResRowBackground())
            }
            .scrollContentBackground(.hidden)
            .background(ResonanceBackdrop().ignoresSafeArea())
            .navigationTitle("You")
            .navigationBarTitleDisplayMode(.inline)
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

/// The top of You: a glass card washed in the viewer's accent with their
/// avatar, name, role and guild, over a faint hive pattern.
private struct IdentityCard: View {
    let name: String
    let username: String
    let guildId: String?
    let role: String
    let isPublic: Bool

    @Environment(\.resAccent) private var accent
    @EnvironmentObject private var toastCenter: ToastCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                ZStack {
                    Hexagon().fill(LinearGradient(colors: [accent, accent.hueShifted(by: 34)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(.black.opacity(0.8))
                }
                .frame(width: 70, height: 80)
                .shadow(color: accent.opacity(0.5), radius: 14)
                VStack(alignment: .leading, spacing: 4) {
                    Text(role.uppercased())
                        .font(Res.eyebrow)
                        .tracking(1.4)
                        .foregroundStyle(accent)
                    Text(name)
                        .font(Res.display(28))
                        .foregroundStyle(Res.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if name != username {
                        Text("@\(username)")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(Res.mist)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if let guildId {
                    Button {
                        UIPasteboard.general.string = guildId
                        Haptics.success()
                        toastCenter.success("Guild ID copied")
                    } label: {
                        Label("Guild \(guildId)", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Label(isPublic ? "Public profile" : "Private profile", systemImage: isPublic ? "globe" : "lock.fill")
            }
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .foregroundStyle(Res.mist)
        }
        .padding(20)
        .background(
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [accent.opacity(0.22), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                HoneycombPattern(color: accent)
                    .frame(width: 180, height: 140)
                    .opacity(0.35)
            }
            .clipShape(RoundedRectangle(cornerRadius: Res.Radius.panel, style: .continuous))
        )
        .resGlass(radius: Res.Radius.panel, elevated: true, edge: accent)
    }
}

/// A faint corner of honeycomb, used as texture behind identity cards.
struct HoneycombPattern: View {
    var color: Color

    var body: some View {
        Canvas { canvas, size in
            let cell: CGFloat = 26
            let height = cell * 2 / sqrt(3)
            var row = 0
            var y: CGFloat = 0
            while y < size.height + height {
                var x: CGFloat = row.isMultiple(of: 2) ? 0 : cell / 2
                while x < size.width + cell {
                    let rect = CGRect(x: x - cell / 2, y: y - height / 2, width: cell * 0.92, height: height * 0.92)
                    let fade = 1 - min(1, hypot(size.width - x, y) / max(size.width, 1))
                    canvas.stroke(Hexagon().path(in: rect), with: .color(color.opacity(0.6 * fade)), lineWidth: 1)
                    x += cell
                }
                y += height * 0.75
                row += 1
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
