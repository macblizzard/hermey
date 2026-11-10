import Foundation

/// How narrow the workspace window may get before its panes have to overlap.
///
/// The shell lays out exactly this much chrome around the conversation: an 8 pt surround on each
/// side, the bot panel at its floor, the divider strip, its hairline — and, when the shared computer
/// is open, that pane and one more hairline. Leaving any of it out is what clipped the conversation's
/// right edge at 624 pt; leaving out the computer pane clipped *both* edges at once, because the
/// `HStack` overflows its window and spills symmetrically.
///
/// The numbers live here, away from AppKit, so the arithmetic can be tested and so the window's
/// minimum, the panes' floors and the "grow the window when a pane opens" helper cannot drift apart.
public enum WindowLayout {
    /// The window surround drawn on each side of the shell.
    public static let surround: CGFloat = 8
    /// The bot panel's narrowest width — the same floor its drag strip allows.
    public static let sidebarFloor: CGFloat = 200
    /// The divider's hit area (the boundary line itself is `hairline`).
    public static let divider: CGFloat = 7
    /// One boundary line.
    public static let hairline: CGFloat = 1
    /// A conversation's narrowest comfortable width when it is the only reading pane.
    public static let conversationMin: CGFloat = 424
    /// A conversation's floor while the shared computer is beside it: two panes share the window, so
    /// the reading pane gives some back instead of pushing the window's edges out of view.
    public static let conversationMinWithComputer: CGFloat = 360
    /// The computer pane's floor, and the width it opens at.
    public static let computerMin: CGFloat = 320
    public static let computerIdeal: CGFloat = 520
    public static let computerMax: CGFloat = 760
    /// The window height below which the shell stops being usable at all.
    public static let heightMin: CGFloat = 560

    /// The narrowest window that can hold the current arrangement.
    ///
    /// - Parameters:
    ///   - sidebarWidth: the bot panel's width, or `nil` when it is hidden — hidden means the panel,
    ///     its divider and its hairline are all gone.
    ///   - panelOpen: whether the shared computer occupies the trailing slot.
    public static func minimumWidth(sidebarWidth: CGFloat?, panelOpen: Bool) -> CGFloat {
        var total = surround * 2
        if let sidebarWidth {
            total += max(sidebarFloor, sidebarWidth) + divider + hairline
        }
        total += panelOpen ? conversationMinWithComputer : conversationMin
        if panelOpen {
            total += hairline + computerMin
        }
        return total
    }
}
