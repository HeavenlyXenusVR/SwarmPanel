import SwiftUI

struct TVLoginView: View {
    @ObservedObject var session: TVSession
    @State private var username = ""
    @State private var password = ""
    @FocusState private var focused: Field?

    private enum Field { case username, password }

    var body: some View {
        VStack(spacing: 36) {
            VStack(spacing: 12) {
                Text("SwarmPanel")
                    .font(.system(size: 76, weight: .heavy, design: .rounded))
                Text("Sign in with your SwarmPanel account to put the live fleet dashboard on this TV.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }

            VStack(spacing: 20) {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focused = .password }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focused, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(signIn)
            }
            .frame(width: 760)

            if let error = session.errorMessage {
                Text(error)
                    .font(.headline)
                    .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.55))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }

            Button(action: signIn) {
                if session.isWorking {
                    ProgressView()
                } else {
                    Text("Sign In").frame(minWidth: 280)
                }
            }
            .disabled(session.isWorking)
        }
        .padding(80)
        .onAppear { focused = .username }
    }

    private func signIn() {
        let name = username
        let secret = password
        Task {
            await session.signIn(username: name, password: secret)
            if session.isAuthenticated { password = "" }
        }
    }
}
