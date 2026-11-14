import SwiftUI
import UIKit

/// A file waiting to be handed to another app.
///
/// A workspace document has to be fetched before it can be shared (the bridge's ticket is single use,
/// so no URL to it can leave the device), which means the item exists *after* a button's action, not
/// when its label is built. `ShareLink` cannot express that; this sheet can.
struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet, for one file on disk.
///
/// This is the phone's only programmatic route to `UIActivityViewController`, and it is deliberately
/// the smallest possible wrapper: the file is on disk, the sheet takes a URL, and nothing here
/// decides what can be done with it — AirDrop, Messages, Files and the rest come from the system.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
