import SwiftUI

/// Placeholder root view for the scaffolding milestone. Replaced by a real
/// auth-gated root (Login/Register -> tab bar) in the next build phase.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("SwarmPanel")
                .font(.title.bold())
            Text("iOS companion — scaffolding milestone")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
