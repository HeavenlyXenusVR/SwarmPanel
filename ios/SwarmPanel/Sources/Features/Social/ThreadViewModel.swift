import Foundation

@MainActor
final class ThreadViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var isSending = false
    @Published var errorMessage: String?

    let accountId: Int
    let peerName: String
    private let api = APIClient.shared

    init(accountId: Int, peerName: String) {
        self.accountId = accountId
        self.peerName = peerName
    }

    func load() async {
        do {
            let response: MessagesResponse = try await api.get("/api/messages/\(accountId)")
            messages = response.messages ?? []
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to load messages."
        }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            let _: OKResponse = try await api.post("/api/messages/\(accountId)", body: SendMessageBody(body: text))
            draft = ""
            await load()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to send message."
        }
    }
}
