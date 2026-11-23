import AppKit
import SwiftUI

/// A window that is only its icon.
///
/// Every property here exists so the desktop never sees a window: no title bar (`.borderless`), no
/// activation when it is clicked (`.nonactivatingPanel`), no fill, no shadow, and no material behind
/// the picture. What is left is the bot's own alpha. The balloon is a separate window so this one is
/// never larger than the icon.
final class DesktopPetPanel: NSPanel {
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
