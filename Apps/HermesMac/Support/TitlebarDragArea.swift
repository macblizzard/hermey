import AppKit
import SwiftUI

/// The strip at the top of the window that behaves like a title bar.
///
/// The window runs with `.hiddenTitleBar`, which buys the seamless look — the sidebar's fill goes
/// all the way to the top edge and the traffic lights sit on the app's own colour — and costs the
/// one interaction every Mac user has in their fingers: drag it to move the window, double-click it
/// to zoom. Neither worked, because there was no title bar left to receive the click.
///
/// So this view stands in for one: it is transparent, it covers only the empty band across the top,
/// and it stays clear of the traffic lights (the caller insets it past them) so the close, minimise
/// and zoom buttons keep their own clicks.
struct TitlebarDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var isOpaque: Bool { false }

        /// A title bar takes the click *and* the drag: one press moves the window, a double press
        /// zooms it. `performDrag(with:)` is the same loop AppKit runs for a real title bar, so
        /// momentum, edge snapping and Spaces all behave.
        override func mouseDown(with event: NSEvent) {
            guard let window = window else { return }
            if event.clickCount == 2 {
                window.zoom(nil)
            } else {
                window.performDrag(with: event)
            }
        }

        /// The window has no focusable chrome here; a click should not steal first responder from
        /// the composer while the user is typing.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
