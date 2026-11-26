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
    /// Whether content that arrives while the reader is at the bottom may pull the transcript down.
    ///
    /// Off while the in-chat search is open. The search owns the reading position then — a match has
    /// been jumped to, and a streaming token that grows the document must not walk the reader away
    /// from the row the chevrons landed on. An explicit `scrollSignal` still scrolls.
    var followsGrowth: Bool = true
    /// Called when the verdict changes. False means "there is something newer below the fold".
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        view.followsGrowth = followsGrowth
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
        view.followsGrowth = followsGrowth
        view.requestScroll(signal: scrollSignal)
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        /// See `ScrollViewportProbe.followsGrowth`.
        var followsGrowth = true

        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private var lastVerdict: Bool?
        private var pendingSignal = Int.min
        private var lastScrolledSignal = Int.min
        /// The document height this probe last saw, so a change of *width* can be told from a change of
        /// height. A pane opening on either edge hands this view a narrower column without a single new
        /// message arriving.
        private var lastDocumentHeight: CGFloat?
        /// One follow in flight at a time. A resize hands the scroll view a frame change per frame of
        /// its animation; without this, each one queued its own four-pass jump and they all landed.
        private var followInFlight = false

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
        ///
        /// Never while the in-chat search is open (`followsGrowth`): the search owns the reading
        /// position, and the reader is looking at a row they jumped to, not at the newest message.
        ///
        /// And only when the **height** grew, not whenever the document's frame changed. Opening a
        /// sidebar or the bot panel animates the conversation's width, and a width is a layout: every
        /// row re-wraps, the document is handed a new frame on every frame of the pane's animation, and
        /// this handler used to take each of those for a new message at the foot and jump the transcript
        /// to its end — once per frame, against an easing move. That is the up-and-down the owner saw
        /// while a sidebar opened or closed (reported 2026-11-25). A width-only change re-measures the
        /// verdict and touches nothing.
        private func contentGrew() {
            let height = enclosingScrollView?.documentView?.frame.height
            let grew = height.map { now in
                guard let last = lastDocumentHeight else { return true }
                return now > last + 0.5
            } ?? false
            if let height { lastDocumentHeight = height }

            if followsGrowth, lastVerdict != false {
                if grew { followGrowth() } else { report() }
            } else {
                report()
            }
            // A lazy transcript grows as it lays out; an open that was already waiting for its
            // rows gets its chance here.
            performPendingScroll()
        }

        /// Follow the growth that arrived, one jump in flight.
        ///
        /// A stream of growth (a reply being written) and a resize both arrive as several frame changes
        /// in a row. The jump already retries while the lazy rows measure themselves, so a second
        /// request while the first is running is the same correction twice — which is what made a
        /// following transcript overshoot and settle, over and over, instead of moving once.
        private func followGrowth() {
            guard !followInFlight else { return }
            followInFlight = true
            scrollToBottom(attempts: 4) { [weak self] in self?.followInFlight = false }
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
        ///
        /// `then` runs once the last attempt has, which is what lets the caller keep exactly one follow
        /// in flight (see `followGrowth`).
        private func scrollToBottom(attempts: Int, then done: (() -> Void)? = nil) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = self.enclosingScrollView, let document = scroll.documentView else {
                    done?()
                    return
                }
                let clip = scroll.contentView
                let distance = document.frame.height - (clip.bounds.origin.y + clip.bounds.height)
                if distance > 0.5 {
                    let target = clip.bounds.origin.y + distance
                    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
                    scroll.reflectScrolledClipView(clip)
                }
                // Our own jump is not growth: keep the baseline current so the next frame change is
                // measured against where the document actually is.
                self.lastDocumentHeight = document.frame.height
                // Re-report: the jump changed the verdict, and the button's visibility follows it.
                self.report()
                if attempts > 1, distance > 0.5 {
                    self.scrollToBottom(attempts: attempts - 1, then: done)
                } else {
                    done?()
                }
            }
        }
    }
}
#endif
