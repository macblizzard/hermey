import AppKit
import SwiftUI

/// Hover reported by **AppKit's own pointer tracking**, for controls whose press belongs to an
/// AppKit cell.
///
/// SwiftUI's `onHover` is a tracking area on the view it is attached to — but only when SwiftUI
/// owns the mouse tracking of that view. A `Menu` with `.borderlessButton` is an `NSPopUpButton`,
/// and a pop-up button runs its own highlight in its cell: the modified SwiftUI view is a host
/// around that cell, and the `mouseEntered`/`mouseExited` SwiftUI would have translated routinely
/// never arrive. The ＋ in the sidebar was wired with `onHoverCompat` on the `Menu` and reported
/// "no mouseover effect" (2026-11-25) after that wiring shipped, which is what this view exists to
/// end: the tracking area is installed by us, in our own `NSView`, so nothing between the pointer
/// and the callback can decline to forward it.
///
/// It is placed as a `.background`, sized by the layout to the control's own box, and it is **not
/// a hit target** — `hitTest` returns nil — so the control in front of it keeps every press, edge
/// and double-press included.
///
/// What it guarantees, in the order the pointer can surprise you:
///
/// * **Any edge, any speed.** AppKit compares the pointer against the area on every move it
///   delivers, so a diagonal entry through a corner is an `enter` exactly as a slow one is, and a
///   fast pass delivers `enter` then `exit` in that order rather than dropping the pair.
/// * **Both ways, always.** The callback is told `true` on enter and `false` on exit — never only
///   on enter. A hover that only ever hears `true` stays bright forever after one pass.
/// * **Appearing under a resting pointer.** A tracking area only fires on a *crossing*. If the
///   control is rebuilt while the pointer is already on it (the sidebar redraws whenever a bot's
///   state changes), no crossing happens and the button would sit at rest under the pointer. So
///   the area's installation re-reads the pointer once and reports the truth.
/// * **A window that stops being key.** `.activeInKeyWindow` stops tracking when the window is not
///   key, and AppKit sends no `exit` for that — so the state is cleared on resign and re-read on
///   become key, rather than being left bright behind another app.
/// * **Re-created, not re-installed.** `updateNSView` only swaps the closure; the view and its
///   tracking area persist, so a SwiftUI update cannot drop the area mid-pass.
struct HoverReporter: NSViewRepresentable {
    /// `true` when the pointer is over the tracked box, `false` when it is not. Called on both.
    var onChange: (Bool) -> Void

    /// No coordinator: the state lives in the `NSView`, which survives SwiftUI updates.
    typealias Coordinator = Void

    func makeNSView(context: Context) -> NSView {
        ReporterView(onChange: onChange)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ReporterView)?.onChange = onChange
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // The view is going away: nothing may call back into a state that no longer has a view.
        (nsView as? ReporterView)?.onChange = nil
    }

    final class ReporterView: NSView {
        var onChange: ((Bool) -> Void)?
        private var area: NSTrackingArea?
        /// What was last reported, so a repeated `enter` at the same pixel is not a state write.
        private var reported: Bool?
        private var windowTokens: [NSObjectProtocol] = []
        /// The belt to the tracking area's braces. A borderless menu's cell eats the crossings
        /// SwiftUI would have forwarded, so a local move monitor samples the pointer directly —
        /// one rect test per move, and it cannot be starved by the control in front.
        private var moveMonitor: Any?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        override var isOpaque: Bool { false }

        /// The control in front of this view owns every click. A background that answers
        /// `hitTest` would take the press and the menu would open on some pixels and not others —
        /// the exact fault the measured keep-out above the row was built to end.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let installed = area { removeTrackingArea(installed) }
            // `.inVisibleRect`: the rect is the view's own visible bounds, kept current by AppKit
            // through every resize and scroll, instead of a rect captured once at install time and
            // stale the moment the panel is dragged narrower.
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            self.area = area
            // Installed mid-hover: no crossing is coming, so read the pointer now — one runloop
            // turn later, because `updateTrackingAreas` runs inside a layout pass and the answer
            // is written into SwiftUI state. The read itself is deferred, not sampled.
            schedulePointerSync()
        }

        override func mouseEntered(with event: NSEvent) {
            report(true)
        }

        override func mouseExited(with event: NSEvent) {
            report(false)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeWindowObservers()
            stopMoveMonitor()
            guard let window else {
                // Out of the hierarchy. The callback is not run: it would write view state during
                // the update that is dismantling this view. Forgetting what was reported is
                // enough — a re-attached view reads the pointer on its next area install.
                reported = nil
                return
            }
            // `.activeInKeyWindow` goes quiet when the window stops being key and sends no exit,
            // so the state is cleared on the way out and re-read on the way back in.
            let center = NotificationCenter.default
            windowTokens = [
                center.addObserver(forName: NSWindow.didResignKeyNotification,
                                   object: window, queue: .main) { [weak self] _ in
                    self?.report(false)
                },
                center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                   object: window, queue: .main) { [weak self] _ in
                    self?.syncToPointer()
                },
            ]
            syncToPointer()
            startMoveMonitor()
        }

        /// Samples the pointer on every move the app receives, whatever control it is over.
        ///
        /// This is the difference between "the event never arrives at this view" and "the event
        /// arrives at the view in front of it": a local monitor sees the *window's* stream, so the
        /// menu cell that owns the pointer cannot starve it. Cheap by construction — one rect test
        /// and a dedupe against the last report.
        private func startMoveMonitor() {
            guard moveMonitor == nil else { return }
            moveMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .scrollWheel]
            ) { [weak self] event in
                self?.syncToPointer()
                return event
            }
        }

        private func stopMoveMonitor() {
            if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
            moveMonitor = nil
        }

        /// Reports what the pointer is doing right now. Used where no crossing can be expected.
        private func syncToPointer() {
            guard let window, window.isKeyWindow else { return }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            report(bounds.contains(point))
        }

        /// The same read, after the current layout pass — see `updateTrackingAreas`.
        private func schedulePointerSync() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.syncToPointer()
            }
        }

        private func report(_ inside: Bool) {
            guard reported != inside else { return }
            reported = inside
            onChange?(inside)
        }

        private func removeWindowObservers() {
            let center = NotificationCenter.default
            for token in windowTokens { center.removeObserver(token) }
            windowTokens = []
        }

        deinit {
            if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
            // `removeObserver` is not main-actor bound and the token is what leaks otherwise.
            let center = NotificationCenter.default
            for token in windowTokens { center.removeObserver(token) }
        }
    }
}
