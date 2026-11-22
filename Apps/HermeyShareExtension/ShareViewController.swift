#if os(iOS)
import SwiftUI
import UIKit

/// The share-sheet entry point.
///
/// A `UIViewController` rather than a storyboard because the content is SwiftUI and the only job
/// here is owning the `NSExtensionContext`: that object is how the sheet opens the app and how it
/// closes itself, and neither capability is available to SwiftUI.
final class ShareViewController: UIViewController {
    private let storage = ShareInboxStorage.live
    private var composer: ShareComposer?
    private var hasCompleted = false

    override func viewDidLoad() {
        super.viewDidLoad()

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let composer = ShareComposer(storage: storage)
        self.composer = composer
        composer.openApp = { [weak self] in self?.handOff() }

        let root = ShareRootView(composer: composer,
                                 items: items,
                                 onCancel: { [weak self] in self?.cancel() })
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        // The sheet's height on iPhone. Tall enough for four bots and the preview, short enough that
        // the caller's app is still visible behind it — a share sheet, not a full-screen trip.
        preferredContentSize = CGSize(width: 0, height: 430)
    }

    // MARK: - Handing off

    /// Brings the app forward on `hermey://share`.
    ///
    /// The payload is already on disk by the time this runs, so the deep link is a convenience, not
    /// the delivery. If iOS declines to open it — some hosts refuse `extensionContext.open`, and it
    /// has returned false since iOS 13 in more than one case — closing the sheet is still correct
    /// and the app drains the same file the next time it launches.
    private func handOff() {
        // Typed explicitly: `self?.complete()` returns `Void?`, and an inferred closure of type
        // `() -> ()?` cannot be handed to `DispatchQueue.async(execute:)`, which wants a `DispatchWorkItem`
        // — the two errors that stopped this target's first build.
        let finish: () -> Void = { [weak self] in self?.complete() }
        guard let context = extensionContext else {
            finish()
            return
        }
        context.open(URL(string: "hermey://share")!) { _ in
            DispatchQueue.main.async(execute: finish)
        }
        // Safety net for a completion that never fires; `complete()` is guarded to run once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: finish)
    }

    private func complete() {
        guard !hasCompleted else { return }
        hasCompleted = true
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancel() {
        guard !hasCompleted else { return }
        hasCompleted = true
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain,
                                                           code: NSUserCancelledError))
    }
}
#endif
