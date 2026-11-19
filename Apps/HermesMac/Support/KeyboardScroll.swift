import AppKit
import SwiftUI

/// Arrow/Page/Home keys scroll the nearest enclosing `NSScrollView`.
///
/// SwiftUI's `ScrollView` on macOS scrolls with the trackpad and the scroll wheel and with nothing
/// else: a focused transcript or bot list ignored the arrow keys entirely (reported 2026-11-19).
/// The scroll view that knows how to scroll is the AppKit one SwiftUI builds underneath, so the
/// keys are answered by finding it and asking it — the same approach the viewport probe already
/// takes for the "am I at the bottom" question, and for the same reason: `ScrollViewProxy` cannot
/// scroll by an amount, only to an id.
@MainActor
final class KeyboardScrollHandle {
    fileprivate weak var scrollView: NSScrollView?

    /// The height of one line of movement. Not the type size: a notch that lands between two rows
    /// reads as "nothing happened".
    private let lineHeight: CGFloat = 44

    var canScroll: Bool { scrollView != nil }

    func line(_ direction: Int) { move(by: lineHeight * CGFloat(direction)) }

    /// A page keeps a line of overlap, so the eye can follow what it was reading across the jump.
    func page(_ direction: Int) {
        guard let scrollView else { return }
        let visible = scrollView.contentView.bounds.height
        move(by: (visible - lineHeight) * CGFloat(direction))
    }

    func toTop() { scroll(to: 0) }

    func toBottom() {
        guard let scrollView else { return }
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        scroll(to: max(0, documentHeight - scrollView.contentView.bounds.height))
    }

    private func move(by delta: CGFloat) {
        guard let scrollView else { return }
        scroll(to: scrollView.contentView.bounds.origin.y + delta)
    }

    private func scroll(to y: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let limit = max(0, document.bounds.height - scrollView.contentView.bounds.height)
        let clamped = min(max(0, y), limit)
        guard abs(clamped - scrollView.contentView.bounds.origin.y) > 0.5 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: clamped))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// Finds the enclosing scroll view and hands it to the handle. Never draws, never takes a click.
struct KeyboardScrollProbe: NSViewRepresentable {
    let handle: KeyboardScrollHandle

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.handle = handle
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.handle = handle
        view.attach()
    }

    final class ProbeView: NSView {
        weak var handle: KeyboardScrollHandle?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        /// The scroll view is not a superview yet when the probe is made — SwiftUI installs it in a
        /// later pass — so this is retried from both the move and the update.
        func attach() {
            guard let scrollView = enclosingScrollView else { return }
            handle?.scrollView = scrollView
        }
    }
}

public extension View {
    /// The half that goes **inside** the scroll view: it finds the AppKit scroll view that actually
    /// scrolls and hands it to `handle`. A background on the `ScrollView` itself cannot do this —
    /// `enclosingScrollView` is nil outside the content.
    func keyboardScrollProbe(_ handle: KeyboardScrollHandle) -> some View {
        background(KeyboardScrollProbe(handle: handle))
    }

    /// The half that goes **on** the scroll view: focus and the keys.
    ///
    /// One handler per key, deciding on the modifier inside it. Registering a separate ⌘↑ handler
    /// beside a plain ↑ one does not work: whichever is declared first consumes the press.
    func keyboardScrolling(_ handle: KeyboardScrollHandle) -> some View {
        self
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { press in
                press.modifiers.contains(.command) ? handle.toTop() : handle.line(-1)
                return .handled
            }
            .onKeyPress(.downArrow) { press in
                press.modifiers.contains(.command) ? handle.toBottom() : handle.line(1)
                return .handled
            }
            .onKeyPress(.pageUp) { _ in handle.page(-1); return .handled }
            .onKeyPress(.pageDown) { _ in handle.page(1); return .handled }
            .onKeyPress(.home) { _ in handle.toTop(); return .handled }
            .onKeyPress(.end) { _ in handle.toBottom(); return .handled }
    }
}
