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
    /// The window surround drawn on each side of the shell. **Zero**: the shell reaches the window
    /// edge on every side, so the frame the traffic lights sit on is the app's own canvas and there
    /// is no band of frame colour to reserve.
    public static let surround: CGFloat = 0
    /// The bot panel's narrowest width — Rakazo's 240 pt floor (`BOTS_SIDEBAR_MIN_WIDTH`), the same
    /// number its drag strip clamps to.
    public static let sidebarFloor: CGFloat = 240
    /// Its widest: `BOTS_SIDEBAR_MAX_WIDTH`.
    public static let sidebarMax: CGFloat = 480
    /// The divider's hit area (the boundary line itself is `hairline`).
    public static let divider: CGFloat = 7
    /// One boundary line.
    public static let hairline: CGFloat = 1
    /// A conversation's narrowest comfortable width when it is the only reading pane.
    public static let conversationMin: CGFloat = 424
    /// A conversation's floor while the shared computer is beside it: two panes share the window, so
    /// the reading pane gives some back instead of pushing the window's edges out of view.
    public static let conversationMinWithComputer: CGFloat = 360
    /// The bot panel's (Rakazo's right panel) floor and the width it opens at.
    public static let computerMin: CGFloat = 320
    public static let computerIdeal: CGFloat = 384
    public static let computerMax: CGFloat = 1000
    /// The bot panel's width — Rakazo's right-hand panel, one step narrower than its roster.
    public static let botPanelWidth: CGFloat = 316
    /// The window height below which the shell stops being usable at all.
    public static let heightMin: CGFloat = 560

    /// The narrowest window that can hold the current arrangement.
    ///
    /// - Parameters:
    ///   - sidebarWidth: the bot panel's width, or `nil` when it is hidden — hidden means the panel,
    ///     its divider and its hairline are all gone.
    ///   - panelOpen: whether the shared computer occupies the trailing slot.
    ///   - botPanelOpen: whether the bot's own panel occupies the trailing slot. It is a pane like
    ///     the computer, so a window that cannot hold it must grow rather than clip it.
    public static func minimumWidth(sidebarWidth: CGFloat?,
                                    panelOpen: Bool,
                                    botPanelOpen: Bool = false) -> CGFloat {
        var total = surround * 2
        if let sidebarWidth {
            total += max(sidebarFloor, sidebarWidth) + divider + hairline
        }
        total += panelOpen ? conversationMinWithComputer : conversationMin
        if panelOpen {
            total += hairline + computerMin
        }
        if botPanelOpen {
            total += hairline + botPanelWidth
        }
        return total
    }
}
