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
    private var pollTask: Task<Void, Never>?

    init(accountId: Int, peerName: String) {
        self.accountId = accountId
        self.peerName = peerName
    }

    /// Mirrors the web thread view's 4s live poll so new incoming messages
    /// show up without leaving and re-entering the conversation.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                await self.load(silent: true)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func load(silent: Bool = false) async {
        do {
            let response: MessagesResponse = try await api.get("/api/messages/\(accountId)")
            messages = response.messages ?? []
            if !silent { errorMessage = nil }
        } catch {
            guard !error.isCancellation, !silent else { return }
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
            guard !error.isCancellation else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to send message."
        }
    }
}
