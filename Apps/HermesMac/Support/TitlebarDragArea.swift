import AppKit
import SwiftUI

/// The strip at the top of the window that behaves like a title bar.
///
/// The window runs with `.hiddenTitleBar`, which buys the seamless look — the sidebar's fill goes
/// all the way to the top edge and the traffic lights sit on the app's own colour — and costs the
/// one interaction every Mac user has in their fingers: drag it to move the window, double-click it
/// to zoom. Neither worked, because there was no title bar left to receive the click.
///
/// So this view stands in for one: it is transparent, it covers the empty band across the top, and
/// it is **full width**. It used to start 96 pt in, which left exactly the band a person aims at —
/// the space above the sidebar's search field — dead: a double-click there did nothing while the
/// same gesture over the conversation zoomed the window. The traffic lights need no gap: they live
/// in the window's own frame view, above this content, and are hit-tested before it.
struct TitlebarDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var isOpaque: Bool { false }

        /// A title bar takes the click *and* the drag: one press moves the window, a double press
        /// does whatever the system says a double press on a title bar does.
        ///
        /// `performDrag(with:)` is the same loop AppKit runs for a real title bar, so momentum,
        /// edge snapping and Spaces all behave.
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                Self.actOnDoubleClick(window)
            } else {
                window.performDrag(with: event)
            }
        }

        /// The window has no focusable chrome here; a click should not steal first responder from
        /// the composer while the user is typing.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// What a double-click on a title bar means is a **system** preference — Desktop & Dock →
        /// "Double-click a window's title bar to". Honouring it is what separates a stand-in title
        /// bar from a Mac that suddenly zooms when its owner asked it not to.
        static func actOnDoubleClick(_ window: NSWindow) {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize"?:
                window.miniaturize(nil)
            case "None"?:
                break
            default:
                // `zoom(nil)` is the same call the green button makes, so the window returns to the
                // size it came from rather than to some computed "maximised" frame.
                window.zoom(nil)
            }
        }
    }
}

/// Lets the window be dragged by any part of its background.
///
/// `.hiddenTitleBar` leaves the window with no title bar at all, and the app now puts its first row
/// on that line — so the 6 pt strip is a convenience, not the only gesture. `isMovableByWindowBackground`
/// keeps the familiar "grab the empty space and move" behaviour, and AppKit still routes clicks to
/// the controls drawn on top of it.
struct WindowMovableByBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { View() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isMovableByWindowBackground = true
        }
    }
}
