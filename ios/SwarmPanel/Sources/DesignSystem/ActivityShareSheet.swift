import SwiftUI
import UIKit

/// UIActivityViewController wrapper — used to share/save an already-downloaded
/// local file (exports CSVs). Simpler and more reliable here than fighting
/// SwiftUI's ShareLink async-Transferable loading model for a file that's
/// already on disk.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
