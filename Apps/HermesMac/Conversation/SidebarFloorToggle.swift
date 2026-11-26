import HermeyUI
import SwiftUI

/// The bot panel's door while the panel is hidden: on the window's floor, on the line the panel's
/// own bar keeps.
///
/// The toggle is the panel's, not the chat's — Settings on the left of `BotSidebarView.bottomBar`,
/// search and this on the right — and that arrangement is unchanged. What changed is where the door
/// goes when the bar is not on screen. It used to be redrawn inside the chat header's leading
/// `HStack`, so collapsing the panel moved one control from the window's floor to its top-left
/// corner: the button was still there, in a place it had never been (owner: "when sidebar is closed
/// the sidebar icon moves to the top of the sidebar, instead it should be placed near the actual
/// position when sidebar is shown").
///
/// **y — the bar's own line.** The bar is `30 + barInset * 2` tall and centres its 30 pt controls,
/// so its centre is 25 pt above the window's floor (`BotSidebarView.bottomBarHeight`). A 30 pt box
/// (`.bar`, `BarIconScale.of(24)`) inset by `barInset` from the floor has exactly that centre:
/// `barInset + 15 == (30 + barInset * 2) / 2`. The glyph therefore does not move a point when the
/// panel goes, and retuning the bar's inset retunes this line with it.
///
/// **x — the bar's leading inset, not its trailing one.** The bar's toggle sits at
/// `sidebarWidth - barInset - 15` — 291 pt for the panel's default 316. With the panel hidden the
/// composer owns the whole window and is centred in it (960 pt at most, `readingInset` gutters), so
/// that x is inside the composer's card for every window narrower than ~1572 pt: the control would
/// sit on the message field, which reads as a button dropped on the composer, not as "the panel's
/// bar without the panel". The window's leading edge *is* the panel's leading edge, and `barInset`
/// from it is the inset the bar gives Settings — so the door appears where the bar's own left-hand
/// control lives.
///
/// **The floor is not empty.** The floating composer's card starts at `readingInset` (28 pt) and
/// its bottom-left row is the model pill — a capsule 20–46 pt above the floor, its leading edge at
/// 36, its own 12 pt inset putting the glyphs at 48. This disc is 10–40 pt up and 10–40 pt in, so
/// below ~1056 pt of window the gap to that card is under 8 pt, and below ~1040 pt the card's
/// rounded leading corner is inside the disc's outer edge; at the 424 pt minimum the pill's rounded
/// end is grazed by a few points (its text is never within 8 pt of the disc). Nothing else is: the
/// plus sits in the row above, which starts at 52 pt — 12 pt clear of this disc's top edge. The
/// disc carries its own surface for exactly this reason: the bar's fill left with the panel, and a
/// bare glyph over a glass card reads as part of it.
struct SidebarFloorToggle: View {
    /// What VoiceOver and the tooltip say — the same sentence the header's copy used.
    static let label = "Show the bot panel"

    let action: () -> Void

    /// The bar's edge inset, read from the panel rather than copied, so the floor line cannot
    /// drift away from the bar's own.
    private static let inset: CGFloat = BotSidebarView.barInset

    var body: some View {
        HermeyIconButton("sidebar.leading", label: Self.label, size: .bar) {
            action()
        }
        .help(Self.label)
        .accessibilityIdentifier("sidebar.collapsedToggle")
        // No system ring, like every other control in the window.
        .hermeyFocusQuiet()
        // The panel's fill is what this glyph normally sits on, and it left with the panel. It gets
        // its own disc, the way the header's pill carries its own surface, so it reads as floating
        // over the floor rather than pasted onto whatever is under it.
        .background(Circle().fill(Tokens.surface))
        .overlay(Circle().strokeBorder(Tokens.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .padding(.leading, Self.inset)
        .padding(.bottom, Self.inset)
    }
}
