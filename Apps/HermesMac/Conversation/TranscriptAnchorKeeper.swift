#if os(macOS)
import AppKit
import SwiftUI

/// Holds the reading position still while older rows are merged in above it.
///
/// A prepend is the one transcript change that moves content the reader is *not* looking at: rows
/// are inserted above the viewport, the scroll view's own origin does not move, and every row under
/// the finger slides down by the height of the page that arrived. Reported 2026-11-22 — scrolling up
/// into older messages shifted the transcript under the reader on each page.
///
/// The prepend is `AppModel.loadEarlierHistory()` (`transcript.insert(contentsOf:at:0)`). A resume's
/// merge is not one: `TranscriptPaging.merge` keeps the rows the reader already had in front of the
/// incoming page, so its prefix never moves.
///
/// Two pieces, deliberately separate:
///
/// * ``TranscriptAnchorHold`` — the reference the transcript arms *before* SwiftUI lays the merged
///   rows out. Not `@Published` on purpose: arming must not schedule a body pass, because the reader
///   is not being asked to redraw anything.
/// * ``TranscriptAnchorKeeper`` — the AppKit half. It reads the clip view's origin and the
///   document's height at the moment of arming and, on the layout that follows, moves the clip to
///   where those two numbers say the reader's row still is. That is the exact inverse of what the
///   prepend did, and it needs no knowledge of which row is where.
///
/// Reading the pre-merge numbers *at arm time* rather than inferring them later is what makes this
/// safe either way: if SwiftUI already held the position itself, the target equals the origin the
/// clip is already at and nothing moves.
///
/// Why the clip view rather than `scrollPosition(id:)` with `scrollTargetLayout`: the same reason
/// `ScrollViewportProbe` exists. This transcript's position is already owned by three SwiftUI
/// mechanisms — `ScrollViewReader` jumps for search, the probe's jump to the newest message, and the
/// pane's scroll keys — and a `scrollPosition` binding would be a fourth opinion competing with them
/// for the same scroll view. Restoring by row geometry (remember the top row, scroll it back) is
/// also inexact in a `LazyVStack`: everything above the viewport is *estimated*, so the id that was
/// anchored gets re-measured as the reader scrolls and the position drifts a little per page. Offset
/// arithmetic has neither problem and costs two numbers.
final class TranscriptAnchorHold {
    /// Where the clip sat and how tall the document was, as of one instant.
    struct Position {
        var origin: CGFloat
        var height: CGFloat
    }

    /// How long a merge's layout may take before the arm is treated as stale.
    ///
    /// A lazy transcript lays itself out within a frame or two. The window exists only so an arm
    /// that never met a merge cannot go on to absorb somebody else's growth — a streaming reply
    /// arriving a minute later must not be pulled into a held position.
    private static let window: TimeInterval = 0.75

    /// The position being held, or nil when nothing is in flight.
    private(set) var armed: Position?
    private var armedAt = Date.distantPast

    /// The keeper that owns the clip view. Weak, and re-installed on attach: this object belongs to
    /// the SwiftUI view's identity, while the AppKit view under it can be built more than once.
    weak var keeper: TranscriptAnchorKeeper.KeeperView?

    /// True while a merge is expected or still laying out.
    var isLive: Bool { armed != nil && Date().timeIntervalSince(armedAt) < Self.window }

    /// Arm for the merge that is about to land, reading the scroll view *now* — before the rows are
    /// laid out, which is the only moment the pre-merge numbers exist.
    ///
    /// A reader pinned to the newest message is not holding a reading position — the transcript's
    /// own follow owns that case — so this is a no-op there. That guard is what keeps the live tail
    /// following new messages exactly as it did before.
    func hold(pinnedToBottom: Bool) {
        guard !pinnedToBottom, let keeper else { return }
        // A merge that is already armed keeps the snapshot it has: it is the earliest one, and the
        // only one taken while the rows were still where the reader left them. A second door to the
        // same merge (the tap, the model's counter, the row count) only widens the window — the
        // arithmetic is absolute, so an older baseline is not an over-correction, it is the truth.
        if armed != nil, isLive {
            armedAt = Date()
            return
        }
        guard let now = keeper.readingPosition else { return }
        armed = now
        armedAt = Date()
    }

    /// The merge has settled, or the reader took the position back.
    func release() {
        armed = nil
    }
}

/// The AppKit half of ``TranscriptAnchorHold``: keeps the clip view where the reader left it.
///
/// It lives inside the scroll content (a `background`) and walks up to the enclosing `NSScrollView`,
/// the way `ScrollViewportProbe` does — so it works whether or not SwiftUI wraps the content in
/// something of its own. It never draws, never takes a click, and never animates: a held position
/// that eased into place would be the jump it is meant to hide.
struct TranscriptAnchorKeeper: NSViewRepresentable {
    let hold: TranscriptAnchorHold

    func makeNSView(context: Context) -> KeeperView { KeeperView(hold: hold) }

    func updateNSView(_ view: KeeperView, context: Context) {
        view.hold = hold
    }

    final class KeeperView: NSView {
        var hold: TranscriptAnchorHold

        private var frameObserver: NSObjectProtocol?
        private var boundsObserver: NSObjectProtocol?
        /// Where this keeper last put the clip, so a move the reader makes is never mistaken for
        /// layout and never fought.
        private var applied: CGFloat?
        /// Ends the hold once the merge's layout has stopped arriving.
        private var settle: DispatchWorkItem?

        init(hold: TranscriptAnchorHold) {
            self.hold = hold
            super.init(frame: .zero)
        }

        // SwiftUI never unarchives this view; returning nil here would have to come after every
        // stored property was initialised, which is more ceremony than the path is worth.
        required init?(coder: NSCoder) { fatalError("TranscriptAnchorKeeper is built by SwiftUI, not a nib") }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit { detach() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() } else { attach() }
        }

        /// The two numbers a merge has to be measured against, read from the scroll view itself.
        var readingPosition: TranscriptAnchorHold.Position? {
            guard let scroll = enclosingScrollView, let document = scroll.documentView else { return nil }
            return .init(origin: scroll.contentView.bounds.origin.y, height: document.frame.height)
        }

        // MARK: Attaching

        private func attach() {
            guard let scroll = enclosingScrollView else {
                // Inside the document view; on the first pass SwiftUI may not have installed it in
                // the scroll view yet.
                DispatchQueue.main.async { [weak self] in self?.attach() }
                return
            }
            detach()

            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.clipMoved() }

            if let document = scroll.documentView {
                document.postsFrameChangedNotifications = true
                frameObserver = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: document, queue: .main
                ) { [weak self] _ in self?.contentChanged() }
            }

            hold.keeper = self
        }

        private func detach() {
            settle?.cancel()
            settle = nil
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            frameObserver = nil
            boundsObserver = nil
            if hold.keeper === self { hold.keeper = nil }
        }

        // MARK: Holding

        /// The content changed size. If a merge is in flight, that growth landed *above* the
        /// viewport, so the clip has to move down by exactly as much to keep the reader's row still.
        private func contentChanged() {
            guard let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            guard let armed = hold.armed, hold.isLive else {
                // Nothing in flight: this is the live turn growing below the fold, which is not a
                // reading position and must not be compensated.
                hold.release()
                applied = nil
                return
            }
            let growth = document.frame.height - armed.height
            guard growth > 0.5 else { return }

            let target = armed.origin + growth
            // One turn later, so SwiftUI has finished laying the page out and anything it did to the
            // clip itself is included in the origin this compares against.
            DispatchQueue.main.async { [weak self] in self?.restore(to: target) }
        }

        private func restore(to target: CGFloat) {
            guard hold.armed != nil, let scroll = enclosingScrollView else { return }
            let clip = scroll.contentView
            // Recorded *before* the move: `clip.scroll` posts its bounds change synchronously, and
            // this keeper's own move must not be read as the reader dragging the page.
            applied = target
            // Not animated, and skipped when the clip is already there: a move that changes nothing
            // still costs a layout.
            if abs(clip.bounds.origin.y - target) > 0.5 {
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
                scroll.reflectScrolledClipView(clip)
            }
            scheduleRelease()
        }

        /// End the hold once the layout has stopped.
        ///
        /// A merge can arrive in more than one chunk (estimated heights replaced by real ones), so
        /// the window is widened by each chunk and closed a beat after the last — which keeps a
        /// streaming turn that grows the transcript later from being folded into a stale position.
        private func scheduleRelease() {
            settle?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hold.release()
                self.applied = nil
            }
            settle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        /// The reader took the position back — a drag, a page key, the jump-to-newest control.
        /// Never fight a finger: the arm goes with it.
        private func clipMoved() {
            guard let applied, let scroll = enclosingScrollView else { return }
            guard abs(scroll.contentView.bounds.origin.y - applied) > 1.5 else { return }
            hold.release()
            self.applied = nil
        }
    }
}
#endif
