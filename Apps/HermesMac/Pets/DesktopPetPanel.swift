import AppKit
import SwiftUI

/// A window that is only its icon.
///
/// Every property here exists so the desktop never sees a window: no title bar (`.borderless`), no
/// activation when it is clicked (`.nonactivatingPanel`), no fill, no shadow, and no material behind
/// the picture. What is left is the bot's own alpha. The balloon is a separate window so this one is
/// never larger than the icon.
///
/// `hasShadow` stays false even though the pet now looks like it floats: a window shadow follows the
/// window's rectangle, not the icon's alpha, so it would draw a grey square around a blob. The drop
/// shadow is SwiftUI's, on the icon itself, inside the clear window (see `PetView`).
///
/// It also *moves* itself. A drag used to be a SwiftUI `DragGesture` that wrote a translation into
/// view state and let the controller set the frame from a SwiftUI update: two hops per frame, and an
/// animated set-frame at the end, which is what made the pet trail the pointer. Here the pointer's
/// delta is applied to the origin the button went down on and `setFrameOrigin` is called straight
/// away, on the event's own turn. Nothing animates, nothing lays out, and the window is never a
/// frame behind the cursor.
final class DesktopPetPanel: NSPanel {
    /// Where the window was when the button went down, and where the pointer was: a drag is one
    /// delta applied to one origin, not a running total.
    private var dragOrigin: NSPoint?
    private var dragMouse: NSPoint?
    private var didDrag = false

    /// A release that moved the pet, with the origin it ended at — where the position is saved.
    var onMoved: ((NSPoint) -> Void)?
    /// A release that never moved: a click, which opens the balloon.
    var onClick: (() -> Void)?
    /// A drag has started, so the controller stops re-deciding click-through until it ends.
    var onDragBegan: (() -> Void)?
    /// Where the pet may sit, applied to a proposed origin. The controller supplies it: that rule is
    /// `PetGeometry.clamp`, and it belongs in one place.
    var clampOrigin: ((NSPoint) -> NSPoint)?

    init(side: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Above ordinary windows, on every Space, and over a full-screen app where macOS allows it.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // A borderless panel has no traffic lights; this keeps it that way if the mask ever grows.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        // Click-through by default: the controller's cursor watch turns it back on over the icon.
        // Starting closed means the first frame of an appearing pet never eats a click.
        ignoresMouseEvents = true
    }

    /// A pet is never the keyboard's target: the balloon takes typing, and only when clicked.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Dragging and clicking

    /// Left-button events are the pet's: the window moves itself, and a release that never moved is
    /// the click that opens the balloon.
    ///
    /// Handled in `sendEvent` rather than on the content view because this *is* the window's
    /// behaviour — and because a view-level handler would still be behind SwiftUI's own hit testing.
    /// The event is still forwarded, so the view keeps its context menu.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragOrigin = frame.origin
            dragMouse = NSEvent.mouseLocation
            didDrag = false
        case .leftMouseDragged:
            follow()
        case .leftMouseUp:
            finish()
        default:
            break
        }
        super.sendEvent(event)
    }

    /// Move to the origin the drag started from plus the pointer's delta, now.
    private func follow() {
        guard let start = dragOrigin, let from = dragMouse else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - from.x
        let dy = mouse.y - from.y
        if !didDrag {
            // Two points of travel is a drag, not the tremor of a click.
            guard abs(dx) + abs(dy) > 2 else { return }
            didDrag = true
            onDragBegan?()
        }
        let proposed = NSPoint(x: start.x + dx, y: start.y + dy)
        setFrameOrigin(clampOrigin?(proposed) ?? proposed)
    }

    private func finish() {
        guard dragOrigin != nil else { return }
        let moved = didDrag
        dragOrigin = nil
        dragMouse = nil
        didDrag = false
        if moved {
            onMoved?(frame.origin)
        } else {
            onClick?()
        }
    }
}

/// The pet's content view: a clear host for the icon that refuses hits on its own transparency.
///
/// A 96 pt square window that answers every click would be an invisible widget over the desktop, and
/// the corners around a blob-shaped body are mostly empty. `hitTest` returns nil wherever the icon's
/// alpha is zero, so those points are not the pet; the panel's cursor watch turns that into a real
/// click-through at the window-server level (a window that simply declines the hit still swallows
/// the click on macOS).
final class PetHitTestView: NSView {
    /// Rebuilt when the bot's face changes: the shape (or the photo's alpha) is the hit area.
    var iconMask: PetIconMask?
    /// The clear ring around the icon inside this view, where the idle motion has room to move.
    var iconInset: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the superview's space; the mask is in the icon's own top-left space,
        // which is also the space `BotAvatarShape.path(inSide:)` draws in.
        let local = superview.map { convert(point, from: $0) } ?? point
        let iconRect = bounds.insetBy(dx: iconInset, dy: iconInset)
        guard iconRect.contains(local) else { return nil }
        guard let iconMask else { return nil }
        let iconPoint = CGPoint(x: local.x - iconRect.minX, y: iconRect.maxY - local.y)
        guard iconMask.hasInk(at: iconPoint) else { return nil }
        return super.hitTest(point)
    }

    /// A pet takes the first click too: clicking a desktop icon should open it, not wake the app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var isOpaque: Bool { false }
}
