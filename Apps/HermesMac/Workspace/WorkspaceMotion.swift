import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The motions in this window, in one place.
///
/// They used to be spelled differently at each call site — the palette at 140 ms with `.easeOut`, the bot
/// panel at 160 ms, the sidebar with no animation at all — which is what "opening and closing is janky"
/// looked like from the outside (reported 2026-11-17): two doors moved at different speeds and one snapped.
///
/// **The two sidebars are one motion.** The bot list leaves the leading edge and the bot's panel arrives
/// at the trailing edge; two panes making room for the same conversation have to move at the same speed
/// and on the same curve, or the window reads as two separate things happening (reported again
/// 2026-11-25: "can we make this smoother with animations without this janky motion?"). So there is one
/// pane animation here and it is named for neither edge — a second one is a second pair of numbers
/// waiting to be written, which is how 160 ms and 180 ms met the first time.
///
/// Every value here is opacity plus a few points of translation: no per-frame layout work, so a sheet or
/// a pane can move while the transcript stays still. Reduce Motion turns them into zero-duration
/// animations rather than removing them — the state still changes, it just lands on the first frame, and
/// the layout it lands on is the same one.
enum WorkspaceMotion {
    /// The compositor's answer to Reduce Motion, read at use time: the setting can change while the app
    /// is running, and a stored Bool would go stale exactly when someone needs it.
    static var reduceMotion: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        false
        #endif
    }

    /// How long a pane takes to leave or enter a window edge. One number for both sidebars.
    private static let paneDuration: Double = 0.18

    /// A pane leaving or entering a window edge — the bot list on the left, the bot's panel on the
    /// right, and the shared computer that borrows the panel's slot. **Both sidebars, one name**: a
    /// second name is a second pair of numbers waiting to be written, which is how 160 ms and 180 ms
    /// met the first time.
    static var sidebar: Animation {
        reduceMotion ? .linear(duration: 0) : .easeInOut(duration: paneDuration)
    }

    /// The command palette's short fade and rise. A floating overlay, not a pane: it is not making room
    /// for anything, so it is the one thing here allowed its own, shorter, one-way curve.
    static var sheet: Animation {
        reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.14)
    }
}
