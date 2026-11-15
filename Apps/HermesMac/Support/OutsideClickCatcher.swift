import AppKit
import SwiftUI

/// A click that lands outside this view puts it away.
///
/// The bot panel is a *pane*, not a popover: SwiftUI dismisses a popover for you, and a pane it
/// does not. Wrapping the shell in a tap-catching backdrop would have been the cheaper answer, but
/// it swallows the click — and the panel's whole point is that the transcript keeps working
/// behind it, so a click that closes the panel must still select the text it landed in.
///
/// Hence a local monitor, the same shape as `EscapeKeyCatcher`: it sees the mouse-down before the
/// window dispatches it, decides whether the click was inside this view's frame, and then hands the
/// event back regardless. Nothing is consumed; the panel's frame is the only thing consulted.
///
/// Installed only while the panel is up (the panel's body owns this view), so a closed panel costs
/// nothing and cannot answer a click that belongs to the transcript.
struct OutsideClickCatcher: NSViewRepresentable {
    /// Called when a mouse-down lands outside the tracked view's frame. Already on the main actor:
    /// local monitors run on the main thread.
    var onOutsideClick: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOutsideClick: onOutsideClick) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.track(view)
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        var onOutsideClick: () -> Void
        private var monitor: Any?
        /// The view whose frame *is* the panel. Weak: SwiftUI may tear the hosting view down before
        /// `dismantleNSView` runs, and a stale pointer must not be dereferenced from a monitor.
        private weak var tracked: NSView?

        init(onOutsideClick: @escaping () -> Void) {
            self.onOutsideClick = onOutsideClick
        }

        func track(_ view: NSView) {
            tracked = view
        }

        func install() {
            guard monitor == nil else { return }
            // Left-click only: a right-click is how the sidebar opens a row's menu, and a panel
            // closing under a menu that is about to appear is a fight the panel would win.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            guard let tracked,
                  let window = tracked.window,
                  // A click in a sheet, a popover or another window is not "outside the panel" —
                  // it belongs to something the panel opened, and that something closes itself.
                  event.window === window else { return }

            let point = tracked.convert(event.locationInWindow, from: nil)
            if tracked.bounds.contains(point) { return }
            onOutsideClick()
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { remove() }
    }
}
