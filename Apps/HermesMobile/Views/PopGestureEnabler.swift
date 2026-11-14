import SwiftUI
import UIKit

/// Puts the edge-swipe back.
///
/// The chat screen draws its own chrome — a floating pill and a floating composer — which means the
/// navigation bar is hidden, and a hidden navigation bar takes UIKit's interactive pop gesture with
/// it: `UINavigationController` refuses the swipe whenever the back button is hidden. The gesture
/// is the phone's own way back and it is not something a redesign gets to remove, so this turns it
/// back on from inside the hierarchy, after the screen has been pushed.
///
/// The delegate is cleared on purpose: it is the object that vetoes the gesture on the root screen,
/// and clearing it is the difference between "swipe works" and "swipe works everywhere except the
/// one screen that was pushed".
struct PopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { Probe() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {
        (controller as? Probe)?.enable()
    }

    final class Probe: UIViewController {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            enable()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enable()
        }

        /// Walks up to the navigation controller that owns this screen and uncorks the swipe.
        func enable() {
            var node: UIViewController? = parent
            while let current = node, !(current is UINavigationController) {
                node = current.parent
            }
            guard let navigation = node as? UINavigationController,
                  navigation.viewControllers.count > 1,
                  let gesture = navigation.interactivePopGestureRecognizer
            else { return }
            // Order matters: UIKit disables the recogniser itself when the bar is hidden, so it is
            // re-enabled before the delegate that would veto it is taken away.
            gesture.isEnabled = true
            gesture.delegate = nil
        }
    }
}

extension View {
    /// For a screen that hides its navigation bar and still wants the swipe back.
    func restoresSwipeBack() -> some View {
        background(PopGestureEnabler().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}
