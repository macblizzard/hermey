import AppKit
import SwiftUI

/// Widens the window when the arrangement needs more room than it has.
///
/// Opening the shared computer puts a third pane in a window that may be narrower than
/// `WindowLayout.minimumWidth(…, panelOpen: true)`. The content minimum alone lets AppKit clip — and an
/// `HStack` that is too wide for its window spills on *both* sides, which is what cut the bot panel's
/// labels and the computer pane's buttons off at once. Growing the window by the missing amount, and
/// never past the screen, keeps the panes whole; nothing is done when the window already fits, so
/// closing the pane never shrinks a window somebody sized themselves.
struct WindowWidthFitter: NSViewRepresentable {
    /// The narrowest content width the current arrangement can use.
    let minimum: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // The window is not attached on the first layout pass, and resizing during layout is how a
        // representable ends up recursing; do it once the pass is over.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            guard content.width + 0.5 < minimum else { return }

            let screen = (window.screen ?? NSScreen.main)?.visibleFrame.width
            var frame = window.frame
            frame.size.width += minimum - content.width
            if let screen, frame.width > screen {
                frame.size.width = screen
            }
            window.setFrame(frame, display: true, animate: false)
        }
    }
}
