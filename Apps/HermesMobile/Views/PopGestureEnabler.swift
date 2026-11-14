import SwiftUI
import UIKit

/// Puts the edge-swipe back.
///
/// The chat screen hides its navigation bar — it draws its own chrome — and a hidden bar takes
/// UIKit's interactive pop gesture with it: the recogniser is disabled, and its delegate refuses to
/// begin. Two halves, so a fix has to answer both:
///
/// 1. `isEnabled` is put back *and kept* put back. The bar re-lays itself out on every appearance
///    and after every push, and each pass is a chance to disable the recogniser again, so the
///    re-arming happens in `viewDidLayoutSubviews` — the one hook that fires after all of them.
/// 2. The delegate is a real object instead of `nil`. `nil` reads as "no veto", which is also no
///    veto on the *root* screen: swipe there, nothing pops, and the recogniser is left wedged so
///    that every later swipe does nothing. This delegate answers with the one fact that matters —
///    is there a screen underneath this one to go back to.
///
/// `navigationController` is asked for directly rather than walking `parent` by hand: SwiftUI wraps
/// a destination in its own hosting controller, and the property knows how to find the stack
/// through that; a hand-rolled walk does not.
struct PopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { Probe() }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        (controller as? Probe)?.enable()
    }

    final class Probe: UIViewController, UIGestureRecognizerDelegate {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            enable()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            enable()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enable()
            // The bar finishes hiding a frame or two after the push settles; re-arm once more after
            // it has, for the case where that pass disables the recogniser one last time.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.enable()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            // Deliberately on every pass: this is the hook that runs *after* the bar has finished
            // hiding itself, which is the moment UIKit disables the recogniser.
            enable()
        }

        /// Idempotent and cheap.
        func enable() {
            guard let navigation = navigationController,
                  let gesture = navigation.interactivePopGestureRecognizer
            else { return }
            if !gesture.isEnabled { gesture.isEnabled = true }
            if gesture.delegate !== self { gesture.delegate = self }
        }

        /// The gesture begins only when there is a screen to go back to.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }

        /// The recogniser lives on the navigation controller's own view; it must not be blocked by
        /// the scroll view's own pan.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

extension View {
    /// For a screen that hides its navigation bar and still wants the swipe back.
    func restoresSwipeBack() -> some View {
        background(
            PopGestureEnabler()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}
