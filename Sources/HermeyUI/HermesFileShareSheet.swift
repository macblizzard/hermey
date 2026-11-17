#if os(iOS)
import SwiftUI
import UIKit

/// A downloaded file ready for the system share sheet. Distinct from the app target's own
/// `SharedFile`: this one lives in HermeyUI so the file cards can present it from shared code.
struct HermesSharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// `UIActivityViewController` with a file URL, not a web URL. iOS only offers "Save to Files" for
/// the former, which is why the card downloads the bytes before presenting this sheet.
struct HermesFileShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
