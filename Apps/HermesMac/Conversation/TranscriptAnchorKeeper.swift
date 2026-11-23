#if os(macOS)
import AppKit
import HermesKit
import SwiftUI

/// One point measurement as the log writes it: no fraction, because half a point is not a fact
/// anybody can act on and two decimals per line is noise in a 400-line ring.
private func anchorPoints(_ value: CGFloat) -> String {
    String(Int(value.rounded()))
}

/// Holds the reading position still while older rows are merged in above it.
///
/// A prepend is the one transcript change that moves content the reader is *not* looking at: rows
/// are inserted above the viewport, the scroll view's own origin does not move, and every row under
/// the finger slides down by the height of the page that arrived. Reported 2026-11-22 — scrolling up
/// into older messages shifted the transcript under the reader on each page.
///
/// The prepend is `AppModel.loadEarlierHistory()` (`transcript.insert(contentsOf:at:0)`), and it is
/// the *only* thing that arms this hold. It used to be inferred as well, from
/// `.onChange(of: model.transcript.count)`: rows grew, the first row's id changed, and the row that
/// had been first was still present. A resume's merge can satisfy all three without prepending
/// anything — `TranscriptPaging.merge` falls back to the incoming page when the two do not overlap,
/// and a refreshed prefix then changes the first row while the reader's rows are still in it — so
/// the hold armed and the keeper moved the clip for a change nobody asked for. That is one of the
/// two reported symptoms ("it jumps"), and the guess is gone: arming is the model's own
/// `earlierLoads` counter and the "load earlier" tap, both of which name the prepend.
///
/// Two pieces, deliberately separate:
///
/// * ``TranscriptAnchorHold`` — the reference the transcript arms *before* SwiftUI lays the merged
///   rows out. Not `@Published` on purpose: arming must not schedule a body pass, because the reader
///   is not being asked to redraw anything.
/// * ``TranscriptAnchorKeeper`` — the AppKit half. It reads the clip view's origin and the
///   document's height at the moment of arming and, on the layout that follows, moves the clip by
///   the growth that landed above it. That is the exact inverse of what the prepend did, and it
///   needs no knowledge of which row is where.
///
/// Reading the pre-merge numbers *at arm time* rather than inferring them later is what makes this
/// safe either way: if SwiftUI already held the position itself, the first correction is a no-op
/// and nothing moves.
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
    /// that never met a prepended page cannot go on to absorb somebody else's growth — a streaming
    /// reply arriving a minute later must not be pulled into a held position.
    private static let window: TimeInterval = 0.75

    /// The position being held, or nil when nothing is in flight.
    private(set) var armed: Position?
    private var armedAt = Date.distantPast

    /// Bumped by every *fresh* arm, never by one that only widens the window.
    ///
    /// The keeper accumulates how much growth it has already corrected. That running total belongs
    /// to one page: carrying it into the next would make the first correction of the new page the
    /// difference between two unrelated heights.
    private(set) var generation = 0

    /// The keeper that owns the clip view. Weak, and re-installed on attach: this object belongs to
    /// the SwiftUI view's identity, while the AppKit view under it can be built more than once.
    weak var keeper: TranscriptAnchorKeeper.KeeperView?

    /// True while a merge is expected or still laying out.
    var isLive: Bool { armed != nil && Date().timeIntervalSince(armedAt) < Self.window }

    /// Arm for the page that is about to land, reading the scroll view *now* — before the rows are
    /// laid out, which is the only moment the pre-merge numbers exist.
    ///
    /// A reader pinned to the newest message is not holding a reading position — the transcript's
    /// own follow owns that case — so this is a no-op there. That guard is what keeps the live tail
    /// following new messages exactly as it did before.
    ///
    /// `reason` is the door that armed, and goes into the log: the two doors are the model's
    /// `earlierLoads` counter (the page arrived) and the "load earlier" tap (the page was asked for),
    /// so a log line naming one proves which path ran.
    func hold(pinnedToBottom: Bool, reason: String = "unspecified") {
        guard !pinnedToBottom else {
            ClientLog.note("anchor skipped — pinned to bottom (\(reason))", category: "paging")
            return
        }
        guard let keeper else {
            ClientLog.note("anchor skipped — no clip view yet (\(reason))", category: "paging")
            return
        }
        // A page that is already armed keeps the snapshot it has: it is the earliest one, and the
        // only one taken while the rows were still where the reader left them. A second door to the
        // same page (the tap, then the counter when it lands) only widens the window — the
        // arithmetic is a delta from that baseline, so an older baseline is not an over-correction,
        // it is the truth.
        if armed != nil, isLive {
            armedAt = Date()
            ClientLog.note("anchor kept — origin \(anchorPoints(armed?.origin ?? 0)) already armed "
                           + "(\(reason))", category: "paging")
            return
        }
        guard let now = keeper.readingPosition else {
            ClientLog.note("anchor skipped — clip view has no document yet (\(reason))", category: "paging")
            return
        }
        armed = now
        armedAt = Date()
        generation &+= 1
        ClientLog.note("anchor armed — origin \(anchorPoints(now.origin)), "
                       + "height \(anchorPoints(now.height)), \(reason)", category: "paging")
    }

    /// The page has settled, or the reader took the position back.
    ///
    /// `reason` separates the three ways a hold ends — settled after the last correction, the reader
    /// moved, a different conversation opened — which is what tells "the keeper fought a drag" from
    /// "the keeper never ran".
    func release(because reason: String = "unspecified") {
        guard let armed else { return }
        let now = keeper?.readingPosition?.origin
        ClientLog.note("anchor released — origin \(now.map { anchorPoints($0) } ?? "-"), "
                       + "was \(anchorPoints(armed.origin)), \(reason)", category: "paging")
        self.armed = nil
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
        /// The growth this hold has already been corrected for: document height minus the height
        /// read at arm time. One prepend, one correction — this is the number that says which
        /// heights have already been answered.
        private var appliedGrowth: CGFloat = 0
        /// Where this keeper has committed the clip to. Corrections move *from* here by the
        /// additional delta, so a re-measure can never re-derive a target that was already applied.
        private var committedOrigin: CGFloat?
        /// The arm these numbers belong to (see `TranscriptAnchorHold.generation`).
        private var generation = 0
        /// Ends the hold once the merge's layout has stopped arriving.
        private var settle: DispatchWorkItem?
        /// When the no-hold line was last written, so a streaming reply cannot fill the ring with it.
        private var lastIdleNote = Date.distantPast

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
            reset()
            if hold.keeper === self { hold.keeper = nil }
        }

        // MARK: Holding

        /// The content changed size.
        ///
        /// With nothing in flight this is the live turn growing below the fold, or a re-measure of
        /// rows nobody is holding — not a reading position, and compensating it would walk the
        /// reader away from their row. It is still worth one line, throttled: a report of "it
        /// jumped" can then be answered with whether the keeper ran at all, instead of guessed at.
        ///
        /// With a hold, the growth landed *above* the viewport (a prepend puts rows in before the
        /// reader's row), so the clip moves down by that much. What it moves by is the *additional*
        /// growth since the last correction — `growth - appliedGrowth` — never the whole of it: a
        /// `LazyVStack` re-measures as it lays out and hands one prepend several heights, and
        /// re-deriving `armed.origin + growth` for each of them re-scrolls the same page over and
        /// over. That repeated correction is the sticky, tugging feel in the report.
        ///
        /// A height that goes back *down* while the hold is live is the same arithmetic the other
        /// way (a row above the viewport measured shorter than it was estimated), so it is corrected
        /// by the negative delta once rather than ignored.
        private func contentChanged() {
            guard let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            guard let armed = hold.armed, hold.isLive else {
                noteChangeWithNoHold(in: scroll, document: document)
                hold.release(because: "the window had closed")
                reset()
                return
            }
            // A new page: its growth is measured from its own baseline, not the last page's total.
            if generation != hold.generation {
                generation = hold.generation
                reset()
            }

            let growth = document.frame.height - armed.height

            // The first look at this page. SwiftUI sometimes holds the position itself, in which
            // case that move is already in the origin — and a correction that ignored it would move
            // the reader twice. Credit what the clip has already moved for, so the delta below is
            // only the part that is still missing. Capped at the growth: a clip that moved further
            // than the page did was moved by the reader, not by the layout.
            if committedOrigin == nil {
                let moved = scroll.contentView.bounds.origin.y - armed.origin
                appliedGrowth = max(0, min(moved, growth))
                committedOrigin = scroll.contentView.bounds.origin.y
            }

            let delta = growth - appliedGrowth
            // The height this hold already answered for. Not a new event, and moving for it is the
            // stick: stop here, which also lets the settle window close on its own.
            guard abs(delta) > 0.5 else { return }

            // From where the clip is committed, not from the snapshot: two changes that arrive
            // before the first correction has run would otherwise both measure the same origin.
            let from = committedOrigin ?? scroll.contentView.bounds.origin.y
            let target = from + delta
            committedOrigin = target
            appliedGrowth = growth
            ClientLog.note("anchor corrected — delta \(anchorPoints(delta)), "
                           + "origin \(anchorPoints(from)) → \(anchorPoints(target)), "
                           + "growth \(anchorPoints(growth))", category: "paging")
            // One turn later, so SwiftUI has finished laying the page out and anything it did to the
            // clip itself is included in the origin this compares against.
            DispatchQueue.main.async { [weak self] in self?.restore(to: target) }
        }

        /// The clip change nobody asked to be held.
        private func noteChangeWithNoHold(in scroll: NSScrollView, document: NSView) {
            let now = Date()
            guard now.timeIntervalSince(lastIdleNote) > 2 else { return }
            lastIdleNote = now
            ClientLog.note("anchor not involved — size change with no hold: "
                           + "origin \(anchorPoints(scroll.contentView.bounds.origin.y)), "
                           + "height \(anchorPoints(document.frame.height))", category: "paging")
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

        /// Forget the numbers of the page that has gone.
        private func reset() {
            applied = nil
            appliedGrowth = 0
            committedOrigin = nil
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
                self.hold.release(because: "the layout settled")
                self.reset()
            }
            settle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        /// The reader took the position back — a drag, a page key, the jump-to-newest control.
        /// Never fight a finger: the arm goes with it.
        private func clipMoved() {
            guard let applied, let scroll = enclosingScrollView else { return }
            guard abs(scroll.contentView.bounds.origin.y - applied) > 1.5 else { return }
            hold.release(because: "the reader moved the transcript")
            reset()
        }
    }
}
#endif
