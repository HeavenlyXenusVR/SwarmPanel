import Foundation

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var displayName = ""
    @Published var bio = ""
    @Published var isPublic = true
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private let api = APIClient.shared

    func load() async {
        do {
            let response: MeResponse = try await api.get("/api/users/me")
            displayName = response.profile.displayName ?? ""
            bio = response.profile.bio ?? ""
            isPublic = response.profile.publicProfile ?? true
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load profile."
        }
    }

    func save(themeAccentHex: String? = nil) async {
        isSaving = true
        statusMessage = nil
        defer { isSaving = false }
        do {
            let _: MeProfileEnvelope = try await api.post(
                "/api/users/me",
                body: ProfileUpdateBody(displayName: displayName, bio: bio, publicProfile: isPublic, themeAccent: themeAccentHex)
            )
            statusMessage = "Profile saved."
            errorMessage = nil
            Haptics.success()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to save profile."
            Haptics.error()
        }
    }
}
