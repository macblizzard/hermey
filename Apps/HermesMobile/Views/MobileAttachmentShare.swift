import Foundation
import UIKit

/// The phone's answer to Quick Look: the system share sheet, handed the cached file.
///
/// iOS has no Finder and no Quick Look window to own, so a document opens the way a file in Mail
/// does — `UIActivityViewController` over the cached URL. It shows the file's own preview on tap and
/// every share destination beside it, and it dismisses itself without a delegate to rotate.
///
/// The bytes were already written into the attachment cache before this is called, so nothing is
/// copied here and nothing lands in the app's Documents directory.
@MainActor
enum MobileAttachmentShare {
    static func present(_ url: URL) {
        guard let host = topViewController() else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // An iPad presents this as a popover and needs somewhere to point the arrow. The middle of
        // the screen, with no arrow, is the honest anchor for a sheet that belongs to a row.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = host.view
            popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY,
                                        width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        host.present(controller, animated: true)
    }

    /// The controller a sheet can be presented from: the frontmost window's deepest presentation.
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
