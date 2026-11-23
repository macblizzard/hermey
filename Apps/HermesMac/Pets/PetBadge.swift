import HermeyUI
import SwiftUI

/// The unread badge: a dot on the icon's top-right corner, and the numbers its hit test reads.
///
/// The geometry lives here, not in the view, because two things have to agree about it: what is
/// drawn, and where the pet answers a click (`PetHitTestView`). A badge drawn outside the tested
/// shape is a badge the owner cannot click — the window would pass the click through to the
/// desktop at exactly the point he is aiming at, and the pet would look broken rather than busy.
///
/// The box is inside the icon's own square: `PetGeometry.iconSide` (96 pt) less the dot and its
/// gap. Nothing here can make the window bigger, so the pet's hit area still ends at its ink.
enum PetBadge {
    /// The dot's diameter, in the icon's own points.
    static let side: CGFloat = 18
    /// The gap between the dot and the icon's top-right corner.
    static let inset: CGFloat = 2

    /// Where the dot sits, in the icon's top-left space — the same space `PetIconMask` answers in.
    static func rect(iconSide: CGFloat) -> CGRect {
        CGRect(x: iconSide - side - inset, y: inset, width: side, height: side)
    }

    /// A dot is round, so its hit is the circle inside that box rather than the box itself: the
    /// corners of an 18 pt square over a blob would be 4 pt of pet that is not there.
    static func contains(_ point: CGPoint, iconSide: CGFloat) -> Bool {
        let rect = rect(iconSide: iconSide)
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        let radius = side / 2
        return dx * dx + dy * dy <= radius * radius
    }
}

/// The badge itself: the count when more than one turn is waiting, a plain dot when there is one.
///
/// The fill is the theme's accent — the pet sits on the desktop, not in the window, so the palette
/// is the only thing that ties the two together — and the white hairline is what makes it read on a
/// light wallpaper, where an accent shape alone would sit nearly invisible on white.
struct PetUnreadBadge: View {
    let count: Int

    var body: some View {
        ZStack {
            Circle().fill(Tokens.accent)
            Circle().strokeBorder(Color.white.opacity(0.92), lineWidth: 1)
            if count > 1 {
                // Two digits are all an 18 pt dot can carry; past that the shape says "a lot".
                Text(count > 9 ? "9+" : "\(count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
        }
        .frame(width: PetBadge.side, height: PetBadge.side)
        // The dot keeps its gap from the corner inside the padded frame, so the whole badge stays
        // in the icon's box (`PetBadge.rect`).
        .padding(PetBadge.inset)
        // The pet's click is the panel's AppKit event, and its menu is the view's: a badge that
        // swallowed either would be a hole in the pet. It is drawn, never a target of its own.
        .allowsHitTesting(false)
    }
}
