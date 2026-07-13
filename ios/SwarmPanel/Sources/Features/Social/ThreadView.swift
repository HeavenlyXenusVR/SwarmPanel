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
                Text(error).foregroundStyle(.red).padding(.horizontal)
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
            }
            .padding()
        }
        .navigationTitle(viewModel.peerName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }

    private func bubble(_ message: ChatMessage, mine: Bool) -> some View {
        Text(message.body)
            .padding(10)
            .background(mine ? Color.accentColor.opacity(0.25) : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
