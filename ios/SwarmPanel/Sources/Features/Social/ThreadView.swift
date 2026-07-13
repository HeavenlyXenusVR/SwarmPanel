import SwiftUI

struct ThreadView: View {
    @StateObject private var viewModel: ThreadViewModel
    @EnvironmentObject private var appState: AppState

    init(accountId: Int, peerName: String) {
        _viewModel = StateObject(wrappedValue: ThreadViewModel(accountId: accountId, peerName: peerName))
    }

    var body: some View {
        VStack {
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(SwarmTheme.danger).padding(.horizontal)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.messages) { message in
                        HStack {
                            if message.senderAccountId != nil && message.senderAccountId == viewModel.accountId {
                                bubble(message, mine: false)
                                Spacer(minLength: 40)
                            } else {
                                Spacer(minLength: 40)
                                bubble(message, mine: true)
                            }
                        }
                    }
                }
                .padding()
            }
            HStack {
                TextField("Message", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button("Send") { Task { await viewModel.send() } }
                    .disabled(viewModel.isSending || viewModel.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .tint(SwarmTheme.accent)
            }
            .padding()
        }
        .background(SwarmTheme.background)
        .navigationTitle(viewModel.peerName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }

    private func bubble(_ message: ChatMessage, mine: Bool) -> some View {
        Text(message.body)
            .foregroundStyle(mine ? .white : SwarmTheme.textPrimary)
            .padding(10)
            .background(mine ? SwarmTheme.accent : SwarmTheme.panel2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
