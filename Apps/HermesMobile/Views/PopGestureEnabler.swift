import SwiftUI
import UIKit

/// Puts the edge-swipe back, by owning it.
///
/// The chat screen hides its navigation bar — it draws its own chrome — and hiding the bar takes
/// UIKit's interactive pop gesture with it. Two earlier attempts tried to *revive* that gesture: put
/// `isEnabled` back, hand it a delegate, re-arm it after the bar finished hiding. Neither worked on
/// device, and the repo's own notes already said why (`docs/UI-PITFALLS.md`, "hiding the bar also
/// kills the edge-swipe pop, and a delegate does not bring it back"). Reviving a disabled system
/// recogniser is a dead end, so this does not try.
///
/// Instead it installs its own `UIScreenEdgePanGestureRecognizer` on the navigation controller's
/// view — the one view every touch in the page is hit-tested through — and pops on a completed
/// left-edge drag. The system recogniser is switched *off* while this one is installed, because two
/// pop recognisers on one pan pop twice.
///
/// Three details that matter:
///
/// - **The host view is full size, not 0×0.** The earlier version was a zero-sized background, so
///   its layout callbacks fired once and never again; every later re-arm was a guess.
/// - **`cancelsTouchesInView = false`** and simultaneous recognition, so the transcript keeps its
///   scroll pan and its own 5 pt drag. The edge band still scrolls vertically — the pop only fires
///   when the drag was more horizontal than vertical.
/// - **The pop is not finger-tracked.** Owning a percent-driven transition is a lot of machinery for
///   a gesture that ends in one animation; this snaps, which reads fine and never half-finishes.
struct PopGestureEnabler: UIViewControllerRepresentable {
    /// Off while something is covering the page — the bot's own sheet, which has its own way out.
    var enabled: Bool = true

    func makeUIViewController(context: Context) -> UIViewController { Probe() }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        (controller as? Probe)?.setEnabled(enabled)
    }

    final class Probe: UIViewController, UIGestureRecognizerDelegate {
        private weak var host: UIView?
        private weak var edgePan: UIScreenEdgePanGestureRecognizer?
        private var isWanted = true

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            install()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        override func willMove(toParent parent: UIViewController?) {
            super.willMove(toParent: parent)
            guard parent == nil else { return }
            // Leaving the screen: take the recogniser with it, and hand the system's back.
            if let edgePan { host?.removeGestureRecognizer(edgePan) }
            edgePan = nil
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        }

        func setEnabled(_ wanted: Bool) {
            isWanted = wanted
            edgePan?.isEnabled = wanted
        }

        func install() {
            guard edgePan == nil, let navigation = navigationController,
                  let target = navigation.view
            else { return }

            let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handle(_:)))
            pan.edges = .left
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delegate = self
            pan.isEnabled = isWanted
            target.addGestureRecognizer(pan)

            host = target
            edgePan = pan
            // Ours is the only pop now.
            navigation.interactivePopGestureRecognizer?.isEnabled = false
        }

        @objc private func handle(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            guard recognizer.state == .ended, let view = host,
                  let navigation,
                  navigation.viewControllers.count > 1
            else { return }
            let translation = recognizer.translation(in: view)
            // More across than up: a vertical drag that starts at the margin belongs to the
            // transcript, not to the way back.
            guard translation.x > 60, abs(translation.x) > abs(translation.y) else { return }
            navigation.popViewController(animated: true)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

extension View {
    /// For a screen that hides its navigation bar and still wants the swipe back.
    ///
    /// The host fills the page rather than collapsing to nothing: a zero-sized representable lays
    /// out once, and a gesture installed from a view that never lays out again cannot be re-armed.
    func restoresSwipeBack(enabled: Bool = true) -> some View {
        background {
            PopGestureEnabler(enabled: enabled)
                .allowsHitTesting(false)
        }
    }
}
