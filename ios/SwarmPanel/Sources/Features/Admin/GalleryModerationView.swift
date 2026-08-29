import SwiftUI

private enum GalleryTab: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case media = "Media"
    case users = "Users"
    var id: String { rawValue }
}

struct GalleryModerationView: View {
    @StateObject private var viewModel = GalleryModerationViewModel()
    @State private var tab: GalleryTab = .activity
    @State private var deleteCommentTarget: GalleryComment?
    @State private var deleteMediaTarget: GalleryMedia?
    @State private var deleteUserTarget: GalleryUser?
    @State private var editUserTarget: GalleryUser?
    @State private var resetPasswordTarget: GalleryUser?
    @State private var newPassword = ""
    @State private var isSelecting = false
    @State private var confirmingBulkDelete = false
    @State private var shareURL: IdentifiableURL?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(GalleryTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .onChange(of: tab) { _ in isSelecting = false }

            switch tab {
            case .activity: activityList
            case .media: mediaList
            case .users: usersList
            }
        }
        .background(SwarmTheme.background)
        .navigationTitle("Gallery Moderation")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if tab == .media || tab == .users {
                    Button(isSelecting ? "Done" : "Select") {
                        isSelecting.toggle()
                        if !isSelecting { viewModel.selectedMediaIds.removeAll(); viewModel.selectedUserIds.removeAll() }
                    }
                    .disabled(tab == .media ? viewModel.media.isEmpty : viewModel.users.isEmpty)
                } else {
                    Button(isSelecting ? "Done" : "Select") {
                        isSelecting.toggle()
                        if !isSelecting { viewModel.selectedCommentIds.removeAll() }
                    }
                    .disabled(viewModel.comments.isEmpty)
                }
            }
        }
        .task { await viewModel.load() }
        .refreshable {
            Haptics.light()
            await viewModel.load()
        }
        .refreshOnForeground { await viewModel.load() }
        .sheet(item: $editUserTarget) { target in
            EditGalleryUserSheet(user: target) { username, displayName, email, publicProfile in
                Task { await viewModel.update(target, username: username, displayName: displayName, email: email, publicProfile: publicProfile) }
            }
        }
        .sheet(item: $shareURL) { item in
            ActivityShareSheet(activityItems: [item.url])
        }
        .alert("Reset Password", isPresented: Binding(get: { resetPasswordTarget != nil }, set: { if !$0 { resetPasswordTarget = nil } })) {
            SecureField("New password", text: $newPassword)
            Button("Cancel", role: .cancel) { resetPasswordTarget = nil }
            Button("Reset") {
                if let target = resetPasswordTarget, newPassword.count >= 8 {
                    Task { await viewModel.resetPassword(target, newPassword: newPassword) }
                }
                resetPasswordTarget = nil
            }
        } message: {
            Text("Enter a new password (min. 8 characters) for \(resetPasswordTarget?.username ?? "this user").")
        }
        .confirmationDialog(
            "Delete this comment?",
            isPresented: Binding(get: { deleteCommentTarget != nil }, set: { if !$0 { deleteCommentTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = deleteCommentTarget { Task { await viewModel.deleteComment(target) } }
                deleteCommentTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteCommentTarget = nil }
        }
        .confirmationDialog(
            "Delete this media item?",
            isPresented: Binding(get: { deleteMediaTarget != nil }, set: { if !$0 { deleteMediaTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = deleteMediaTarget { Task { await viewModel.deleteMedia(target) } }
                deleteMediaTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteMediaTarget = nil }
        }
        .alert("Delete Gallery User", isPresented: Binding(get: { deleteUserTarget != nil }, set: { if !$0 { deleteUserTarget = nil } })) {
            Button("Cancel", role: .cancel) { deleteUserTarget = nil }
            Button("Delete", role: .destructive) {
                if let target = deleteUserTarget { Task { await viewModel.deleteUser(target) } }
                deleteUserTarget = nil
            }
        } message: {
            Text("Permanently delete \(deleteUserTarget?.username ?? "this user")? This cannot be undone.")
        }
        .confirmationDialog(
            "Delete \(selectedCount) item(s)?",
            isPresented: $confirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    switch tab {
                    case .activity: await viewModel.bulkDeleteSelectedComments()
                    case .media: await viewModel.bulkDeleteSelectedMedia()
                    case .users: await viewModel.bulkDeleteSelectedUsers()
                    }
                    isSelecting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var selectedCount: Int {
        switch tab {
        case .activity: return viewModel.selectedCommentIds.count
        case .media: return viewModel.selectedMediaIds.count
        case .users: return viewModel.selectedUserIds.count
        }
    }

    // MARK: - Activity (reports + comments, unchanged)

    private var activityList: some View {
        List {
            if let error = viewModel.errorMessage {
                Section { ErrorBanner(message: error) }
                    .listRowBackground(SwarmTheme.panel)
            }

            Section {
                if viewModel.reports.isEmpty {
                    EmptyStateView(icon: "flag", title: "No reports.")
                } else {
                    ForEach(viewModel.reports) { report in
                        ReportRow(report: report, viewModel: viewModel)
                    }
                }
            } header: {
                SectionLabel(title: "Reports", count: viewModel.reports.count)
            }
            .listRowBackground(SwarmTheme.panel)

            Section {
                if viewModel.comments.isEmpty {
                    EmptyStateView(icon: "bubble.left", title: "No comments.")
                } else {
                    ForEach(viewModel.comments) { comment in
                        HStack(alignment: .top, spacing: 12) {
                            if isSelecting {
                                Image(systemName: viewModel.selectedCommentIds.contains(comment.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(viewModel.selectedCommentIds.contains(comment.id) ? SwarmTheme.accent : SwarmTheme.textMuted)
                            }
                            IconChip(systemName: "bubble.left.fill", tint: .teal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(comment.body ?? "").font(.caption).foregroundStyle(SwarmTheme.textPrimary).lineLimit(2)
                                Text("\(comment.username ?? "unknown") on \(comment.mediaTitle ?? "media")")
                                    .font(.caption2)
                                    .foregroundStyle(SwarmTheme.textMuted)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isSelecting { viewModel.toggleSelection(comment) }
                        }
                        .swipeActions(edge: .trailing) {
                            if !isSelecting {
                                Button(role: .destructive) {
                                    deleteCommentTarget = comment
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            } header: {
                SectionLabel(title: "Comments", count: viewModel.comments.count)
            }
            .listRowBackground(SwarmTheme.panel)
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            if isSelecting && !viewModel.selectedCommentIds.isEmpty {
                bulkBar(count: viewModel.selectedCommentIds.count)
            }
        }
    }

    // MARK: - Media

    private var mediaList: some View {
        List {
            if let error = viewModel.errorMessage {
                Section { ErrorBanner(message: error) }
                    .listRowBackground(SwarmTheme.panel)
            }
            Section {
                if viewModel.media.isEmpty {
                    EmptyStateView(icon: "photo.on.rectangle", title: "No media.")
                } else {
                    ForEach(viewModel.media) { item in
                        MediaRow(
                            item: item, viewModel: viewModel, isSelecting: isSelecting,
                            onDelete: { deleteMediaTarget = item }
                        )
                    }
                }
            } header: {
                SectionLabel(title: "Media", count: viewModel.media.count)
            } footer: {
                Button {
                    Task { if let url = await viewModel.exportMediaCSV() { shareURL = IdentifiableURL(url: url) } }
                } label: {
                    Label(viewModel.isExporting ? "Exporting…" : "Export CSV", systemImage: "square.and.arrow.down")
                }
                .disabled(viewModel.isExporting)
                .font(.caption)
            }
            .listRowBackground(SwarmTheme.panel)
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            if isSelecting && !viewModel.selectedMediaIds.isEmpty {
                bulkBar(count: viewModel.selectedMediaIds.count)
            }
        }
    }

    // MARK: - Users

    private var usersList: some View {
        List {
            if let error = viewModel.errorMessage {
                Section { ErrorBanner(message: error) }
                    .listRowBackground(SwarmTheme.panel)
            }
            if let status = viewModel.statusMessage {
                Section { Text(status).foregroundStyle(SwarmTheme.ok) }
                    .listRowBackground(SwarmTheme.panel)
            }
            Section {
                if viewModel.users.isEmpty {
                    EmptyStateView(icon: "person.crop.circle.badge.questionmark", title: "No users.")
                } else {
                    ForEach(viewModel.users) { user in
                        GalleryUserRow(
                            user: user, viewModel: viewModel, isSelecting: isSelecting,
                            onEdit: { editUserTarget = user },
                            onResetPassword: { resetPasswordTarget = user; newPassword = "" },
                            onDelete: { deleteUserTarget = user }
                        )
                    }
                }
            } header: {
                SectionLabel(title: "Users", count: viewModel.users.count)
            } footer: {
                Button {
                    Task { if let url = await viewModel.exportUsersCSV() { shareURL = IdentifiableURL(url: url) } }
                } label: {
                    Label(viewModel.isExporting ? "Exporting…" : "Export CSV", systemImage: "square.and.arrow.down")
                }
                .disabled(viewModel.isExporting)
                .font(.caption)
            }
            .listRowBackground(SwarmTheme.panel)
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            if isSelecting && !viewModel.selectedUserIds.isEmpty {
                bulkBar(count: viewModel.selectedUserIds.count)
            }
        }
    }

    private func bulkBar(count: Int) -> some View {
        HStack {
            Text("\(count) selected").font(.caption).foregroundStyle(SwarmTheme.textMuted)
            Spacer()
            Button(role: .destructive) {
                confirmingBulkDelete = true
            } label: {
                if viewModel.isBulkDeleting { ProgressView() } else { Text("Delete Selected") }
            }
            .disabled(viewModel.isBulkDeleting)
        }
        .padding(12)
        .background(SwarmTheme.panel)
    }
}

private struct ReportRow: View {
    let report: GalleryReport
    @ObservedObject var viewModel: GalleryModerationViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconChip(systemName: "flag.fill", tint: report.status == "open" ? .red : SwarmTheme.textMuted)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(report.reason?.capitalized ?? "Report")
                        .font(.subheadline.bold())
                        .foregroundStyle(SwarmTheme.textPrimary)
                    Spacer()
                    StatusPill(text: report.status?.capitalized ?? "Open", tone: report.status == "open" ? .soft : .off)
                }
                Text("\(report.username ?? "unknown") on \(report.mediaTitle ?? "media")")
                    .font(.caption2)
                    .foregroundStyle(SwarmTheme.textMuted)
                if let details = report.details, !details.isEmpty {
                    Text(details).font(.caption).foregroundStyle(SwarmTheme.textMuted).lineLimit(2)
                }
                if report.status != "dismissed" {
                    HStack {
                        Button("Reviewed") { Task { await viewModel.setReportStatus(report, status: "reviewed") } }
                            .buttonStyle(.borderless)
                            .tint(SwarmTheme.accent)
                        Button("Dismiss") { Task { await viewModel.setReportStatus(report, status: "dismissed") } }
                            .buttonStyle(.borderless)
                            .tint(SwarmTheme.textMuted)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(14)
    }
}

private struct MediaRow: View {
    let item: GalleryMedia
    @ObservedObject var viewModel: GalleryModerationViewModel
    let isSelecting: Bool
    let onDelete: () -> Void

    private var isSelected: Bool { viewModel.selectedMediaIds.contains(item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? SwarmTheme.accent : SwarmTheme.textMuted)
                }
                IconChip(systemName: "photo.fill", tint: .teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle).font(.subheadline.bold()).foregroundStyle(SwarmTheme.textPrimary)
                    Text("\(item.username ?? "unknown") · \(item.views ?? 0) views · \(item.downloads ?? 0) downloads")
                        .font(.caption2)
                        .foregroundStyle(SwarmTheme.textMuted)
                }
                Spacer()
                if item.isAdult == true {
                    StatusPill(text: "18+", tone: .soft)
                }
                StatusPill(
                    text: item.moderationStatus?.capitalized ?? "Pending",
                    tone: item.moderationStatus == "approved" ? .live : (item.moderationStatus == "rejected" ? .off : .soft)
                )
            }
            if !isSelecting {
                HStack(spacing: 14) {
                    if item.moderationStatus != "approved" {
                        Button("Approve") { Task { await viewModel.setModerationStatus(item, status: "approved") } }
                    }
                    if item.moderationStatus != "rejected" {
                        Button("Reject") { Task { await viewModel.setModerationStatus(item, status: "rejected") } }
                    }
                    Button(item.isAdult == true ? "Unmark 18+" : "Mark 18+") { Task { await viewModel.toggleAdult(item) } }
                    Button("Delete", role: .destructive, action: onDelete)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .tint(SwarmTheme.accent)
            }
        }
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isSelecting else { return }
            viewModel.toggleMediaSelection(item)
        }
    }
}

private struct GalleryUserRow: View {
    let user: GalleryUser
    @ObservedObject var viewModel: GalleryModerationViewModel
    let isSelecting: Bool
    let onEdit: () -> Void
    let onResetPassword: () -> Void
    let onDelete: () -> Void

    private var isSelected: Bool { viewModel.selectedUserIds.contains(user.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? SwarmTheme.accent : SwarmTheme.textMuted)
                }
                InitialsAvatar(name: user.name, diameter: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.name).font(.subheadline.bold()).foregroundStyle(SwarmTheme.textPrimary)
                    Text("\(user.mediaCount ?? 0) media · \(user.commentCount ?? 0) comments")
                        .font(.caption2)
                        .foregroundStyle(SwarmTheme.textMuted)
                }
                Spacer()
                StatusPill(text: user.isEmailVerified ? "Verified" : "Unverified", tone: user.isEmailVerified ? .live : .off)
            }
            if !isSelecting {
                HStack(spacing: 14) {
                    Button("Edit", action: onEdit)
                    Button(user.isEmailVerified ? "Unverify Email" : "Verify Email") {
                        Task { await viewModel.toggleEmailVerified(user) }
                    }
                    Button(user.isAgeVerified ? "Unverify Age" : "Verify Age") {
                        Task { await viewModel.toggleAgeVerified(user) }
                    }
                    if !user.isEmailVerified {
                        Button("Resend Code") { Task { await viewModel.resendVerification(user) } }
                    }
                    Button("Reset Password", action: onResetPassword)
                    Button("Delete", role: .destructive, action: onDelete)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .tint(SwarmTheme.accent)
            }
        }
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isSelecting else { return }
            viewModel.toggleUserSelection(user)
        }
    }
}

private struct EditGalleryUserSheet: View {
    let user: GalleryUser
    let onSave: (String, String, String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var username: String
    @State private var displayName: String
    @State private var email: String
    @State private var publicProfile: Bool

    init(user: GalleryUser, onSave: @escaping (String, String, String, Bool) -> Void) {
        self.user = user
        self.onSave = onSave
        _username = State(initialValue: user.username)
        _displayName = State(initialValue: user.displayName ?? "")
        _email = State(initialValue: user.email ?? "")
        _publicProfile = State(initialValue: user.publicProfile ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Display name", text: $displayName)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Public profile", isOn: $publicProfile)
                }
            }
            .navigationTitle("Edit Gallery User")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(username, displayName, email, publicProfile)
                        dismiss()
                    }
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

#Preview {
    NavigationStack { GalleryModerationView() }
        .environmentObject(ToastCenter())
}
