import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The three motions in this window, in one place.
///
/// They used to be spelled differently at each call site — the palette at 140 ms with `.easeOut`, the bot
/// panel at 160 ms, the sidebar with no animation at all — which is what "opening and closing is janky"
/// looked like from the outside (reported 2026-11-17): two doors moved at different speeds and one snapped.
///
/// Every value here is opacity plus a few points of translation: no per-frame layout work, so a sheet or
/// a pane can move while the transcript stays still. Reduce Motion turns them into zero-duration
/// animations rather than removing them — the state still changes, it just lands on the first frame.
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

    /// A bot panel sliding in from the right, and the sheet chrome around it.
    static var panel: Animation {
        reduceMotion ? .linear(duration: 0) : .easeInOut(duration: 0.16)
    }

    /// A pane leaving or entering the window's left edge.
    static var sidebar: Animation {
        reduceMotion ? .linear(duration: 0) : .easeInOut(duration: 0.18)
    }

    /// The command palette's short fade and rise.
    static var sheet: Animation {
        reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.14)
    }
}
