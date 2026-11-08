import AppKit
import OpenBotUI
import SwiftUI

/// Where the window's transparency setting lives, so the slider and the window read one key.
enum WindowAppearance {
    static let opacityKey = "appearance.windowOpacity"
    /// The floor: below this the transcript is unreadable over a bright desktop.
    static let minimumOpacity = 0.55
}

/// Makes the window genuinely see-through instead of merely faded.
///
/// A window with `isOpaque = true` still paints its background colour behind translucent content,
/// so a faded view alone looks washed out over a solid fill. Clearing the background and letting the
/// window be non-opaque is what puts the desktop behind it — and it has to be restored to the
/// default when the slider goes back to 1, otherwise AppKit keeps compositing a window that has
/// nothing to composite.
struct WindowBackdrop: NSViewRepresentable {
    var opacity: Double

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        // The window only exists once the view is in the hierarchy; first layout lands after this.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let translucent = opacity < 0.999
            if window.isOpaque != !translucent {
                window.isOpaque = !translucent
                window.backgroundColor = translucent ? .clear : NSColor(Tokens.frame)
            }
        }
    }
}
