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
                ErrorBanner(message: error).padding(.horizontal)
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
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message", text: $viewModel.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.system(.body, design: .rounded))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .resGlass(radius: 22)
                let canSend = !(viewModel.isSending || viewModel.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                ResTransportButton(systemImage: "arrow.up", label: "Send", prominent: canSend, size: 44) {
                    Task { await viewModel.send() }
                }
                .disabled(!canSend)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(ResonanceBackdrop().ignoresSafeArea())
        .hidesDock()
        .navigationTitle(viewModel.peerName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
            viewModel.startPolling()
        }
        .onDisappear { viewModel.stopPolling() }
        .refreshable { await viewModel.load() }
        .refreshOnForeground { await viewModel.load() }
    }

    private func bubble(_ message: ChatMessage, mine: Bool) -> some View {
        Text(message.body)
            .font(.system(.body, design: .rounded))
            .foregroundStyle(mine ? Color.black.opacity(0.85) : Res.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                let shape = UnevenRoundedCorners(radius: 20, tailCorner: mine ? .bottomTrailing : .bottomLeading)
                if mine {
                    shape.fill(LinearGradient(colors: [SwarmTheme.accent, SwarmTheme.accentSecondary], startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    shape.fill(.ultraThinMaterial).overlay(shape.fill(Res.surface)).overlay(shape.stroke(Res.hairline, lineWidth: 1))
                }
            }
    }
}

/// A chat-bubble shape: every corner rounded except a smaller "tail"
/// corner on the speaker's side. (A Shape rather than iOS 17's
/// UnevenRoundedRectangle, for the iOS 16 deployment target.)
struct UnevenRoundedCorners: Shape {
    enum Corner { case bottomLeading, bottomTrailing }

    var radius: CGFloat
    var tailCorner: Corner
    var tailRadius: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let tl = radius, tr = radius
        let bl = tailCorner == .bottomLeading ? tailRadius : radius
        let br = tailCorner == .bottomTrailing ? tailRadius : radius
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}
