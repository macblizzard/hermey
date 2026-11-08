#if os(macOS)
import AppKit
import SwiftUI

/// Whether the transcript is at its newest message, and the way to put it there.
///
/// Three SwiftUI-only attempts failed for honest reasons: `onAppear`/`onDisappear` do not fire for
/// a plain view that scrolls out of a `ScrollView`; a geometry preference compared values that
/// never disagreed; and `ScrollViewProxy.scrollTo` runs before a `LazyVStack` has laid out its rows,
/// so a freshly opened conversation landed in the middle of its own history.
///
/// The scroll view itself holds both facts exactly — its clip view's origin and its document's
/// height — so this probe reads them from AppKit and does the jump the same way. It lives inside
/// the scroll content (a `background`) and walks up to the enclosing `NSScrollView`, which is why
/// it works whether or not SwiftUI decides to wrap the content in something of its own.
struct ScrollViewportProbe: NSViewRepresentable {
    /// Bump to ask for the newest message. A counter, not a flag: two requests in a row (open, then
    /// a send that lands) must scroll twice.
    var scrollSignal: Int
    /// Called when the verdict changes. False means "there is something newer below the fold".
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
        view.requestScroll(signal: scrollSignal)
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?

        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private var lastVerdict: Bool?
        private var pendingSignal = Int.min
        private var lastScrolledSignal = Int.min

        /// The probe never draws and never takes a click: it is a measuring device, not a view.
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                detach()
            } else {
                attach()
            }
        }

        deinit { detach() }

        // MARK: Attaching

        private func attach() {
            guard let scroll = enclosingScrollView else {
                // The probe is inside the document view; on the first pass SwiftUI may not have
                // installed it in the scroll view yet.
                DispatchQueue.main.async { [weak self] in self?.attach() }
                return
            }
            detach()

            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.report() }

            if let document = scroll.documentView {
                document.postsFrameChangedNotifications = true
                frameObserver = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: document, queue: .main
                ) { [weak self] _ in
                    self?.contentGrew()
                }
            }

            report()
            performPendingScroll()
        }

        private func detach() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            boundsObserver = nil
            frameObserver = nil
        }

        // MARK: Measuring

        /// Points still to scroll before the newest message is flush with the bottom.
        private var distanceToBottom: CGFloat? {
            guard let scroll = enclosingScrollView, let document = scroll.documentView else { return nil }
            let clip = scroll.contentView
            return document.frame.height - (clip.bounds.origin.y + clip.bounds.height)
        }

        private func report() {
            guard let distance = distanceToBottom else { return }
            // 28 pt of slack: a reply that has just started is "at the bottom" although its last
            // line may still sit a hair below the fold.
            let atBottom = distance < 28
            guard atBottom != lastVerdict else { return }
            lastVerdict = atBottom
            let callback = onChange
            DispatchQueue.main.async { callback?(atBottom) }
        }

        /// Content grew: follow it if the transcript was pinned to the bottom.
        ///
        /// Growth used to be reported exactly like a scroll. The document got taller, the clip
        /// stayed where it was, and the verdict flipped to "not at the bottom" — so the moment a
        /// live card, a commentary row or a line of reasoning arrived, following switched itself
        /// off and everything after that landed below the fold. A growth is not a decision by the
        /// reader; only a scroll is.
        private func contentGrew() {
            if lastVerdict != false {
                scrollToBottom(attempts: 4)
            } else {
                report()
            }
            // A lazy transcript grows as it lays out; an open that was already waiting for its
            // rows gets its chance here.
            performPendingScroll()
        }

        // MARK: Scrolling

        func requestScroll(signal: Int) {
            pendingSignal = signal
            performPendingScroll()
        }

        private func performPendingScroll() {
            guard pendingSignal != lastScrolledSignal, enclosingScrollView != nil else { return }
            lastScrolledSignal = pendingSignal
            scrollToBottom(attempts: 8)
        }

        /// Jump to the end and keep going while the transcript is still laying out.
        ///
        /// One jump is not enough: each new lazy row pushes the end further down, so the first
        /// attempt lands short of the bottom by however much the last screens of history added.
        private func scrollToBottom(attempts: Int) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = self.enclosingScrollView, let document = scroll.documentView else {
                    return
                }
                let clip = scroll.contentView
                let distance = document.frame.height - (clip.bounds.origin.y + clip.bounds.height)
                if distance > 0.5 {
                    let target = clip.bounds.origin.y + distance
                    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
                    scroll.reflectScrolledClipView(clip)
                }
                // Re-report: the jump changed the verdict, and the button's visibility follows it.
                self.report()
                if attempts > 1, distance > 0.5 {
                    self.scrollToBottom(attempts: attempts - 1)
                }
            }
        }
    }
}
#endif
