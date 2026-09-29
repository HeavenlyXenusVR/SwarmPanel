import SwiftUI

/// SwarmPanel for Apple TV: the Dashboard only, read-only. No Controls
/// (there's no practical way to paste a YouTube link with a Siri Remote)
/// and never admin mode -- the session is requested with admin mode off
/// (see TVSession.signIn), so the TV always shows the account's own
/// guild-scoped view. Background, accent and profile follow the account's
/// web settings live (TVAccountModel).
@main
struct SwarmPanelTVApp: App {
    @StateObject private var session = TVSession()
    @StateObject private var account = TVAccountModel()

    var body: some Scene {
        WindowGroup {
            ZStack {
                TVPanelBackground(account: account)
                if session.isAuthenticated {
                    TVDashboardView(session: session, account: account)
                } else {
                    TVLoginView(session: session)
                }
            }
            .preferredColorScheme(.dark)
            .onChange(of: session.isAuthenticated) { _, signedIn in
                if signedIn { account.start() } else { account.stop() }
            }
            .onAppear {
                if session.isAuthenticated { account.start() }
            }
        }
    }
}
