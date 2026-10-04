import LocalAuthentication
import SwiftUI

/// Optional Face ID / Touch ID gate in front of the whole app — opt-in via
/// Profile > Advanced, off by default. Locks on cold launch and whenever the
/// app returns from the background, since that's when someone else could
/// have picked up the phone.
@MainActor
final class BiometricLock: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { isUnlocked = true }
        }
    }
    @Published private(set) var isUnlocked: Bool

    private static let enabledKey = "swarmpanel.biometricLockEnabled"

    init() {
        let enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        isEnabled = enabled
        isUnlocked = !enabled
    }

    var biometryLabel: String {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return "Passcode"
        }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Passcode"
        }
    }

    func lock() {
        guard isEnabled else { return }
        isUnlocked = false
    }

    func attemptUnlock() async {
        guard isEnabled, !isUnlocked else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // No biometrics/passcode enrolled on this device — don't lock
            // the user out of an app they can't otherwise unlock.
            isUnlocked = true
            return
        }
        let success = await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock SwarmPanel") { success, _ in
                continuation.resume(returning: success)
            }
        }
        isUnlocked = success
    }
}

struct BiometricLockOverlay: View {
    @ObservedObject var lock: BiometricLock

    var body: some View {
        if lock.isEnabled && !lock.isUnlocked {
            ZStack {
                ResonanceBackdrop().ignoresSafeArea()
                VStack(spacing: 22) {
                    ResonanceEmblem(size: 132)
                    VStack(spacing: 6) {
                        Text("SwarmPanel is locked")
                            .font(Res.display(26))
                            .foregroundStyle(Res.ink)
                        Text("The fleet keeps playing while you're away.")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(Res.mist)
                    }
                    Button {
                        Task { await lock.attemptUnlock() }
                    } label: {
                        Label("Unlock with \(lock.biometryLabel)", systemImage: "faceid")
                    }
                    .buttonStyle(ResPrimaryButtonStyle())
                    .frame(maxWidth: 320)
                }
                .padding(32)
            }
            .task { await lock.attemptUnlock() }
        }
    }
}
