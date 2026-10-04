import SwiftUI

struct TVLoginView: View {
    @ObservedObject var session: TVSession
    @State private var username = ""
    @State private var password = ""
    @FocusState private var focused: Field?

    private enum Field { case username, password }

    var body: some View {
        HStack(spacing: 100) {
            VStack(alignment: .leading, spacing: 28) {
                ResonanceEmblem(size: 260)
                Text("SwarmPanel")
                    .font(TVRes.display(92))
                Text("Put the live fleet on this TV: every bot in the hive, what it's playing, and the Medic's watch — read-only.")
                    .font(.system(size: 30, design: .rounded))
                    .foregroundStyle(TVRes.mist)
                    .frame(maxWidth: 760, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 26) {
                Text("SIGN IN")
                    .font(TVRes.eyebrow)
                    .tracking(2)
                    .foregroundStyle(TVRes.mist)
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

                if let error = session.errorMessage {
                    Text(error)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(TVRes.danger)
                        .frame(maxWidth: 640, alignment: .leading)
                }

                Button(action: signIn) {
                    if session.isWorking {
                        ProgressView()
                    } else {
                        Text("Sign In").frame(minWidth: 300)
                    }
                }
                .disabled(session.isWorking)
            }
            .padding(50)
            .frame(width: 740)
            .tvGlass(radius: 44)
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
