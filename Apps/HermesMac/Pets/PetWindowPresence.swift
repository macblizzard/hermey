import AppKit

/// Whether the owner is looking at the Hermey window right now.
///
/// A reply he can see earns no hop — the badge is enough, and he is reading the answer anyway. Two
/// states mean he cannot see it, and they are different properties: a minimised window is
/// `isMiniaturized` *and* has stopped being `isVisible`, while a hidden app (`⌘H`) answers only
/// `NSApp.isHidden` and leaves the window's own flags alone. All three are asked.
///
/// The workspace window is the app's window that can become main and is not a panel. Every pet
/// panel and every balloon is an `NSPanel` and declines both, so a pet can never be mistaken for
/// the window it is reporting on. No such window at all — closed, or not made yet — is away too:
/// nothing is showing him the answer.
///
/// `@MainActor` because AppKit's own globals are: this is asked from the controller, on the main
/// actor, where the pets already live.
@MainActor
enum PetWindowPresence {
    static func isAway() -> Bool {
        if NSApp.isHidden { return true }
        let workspace = NSApp.windows.filter { $0.canBecomeMain && !($0 is NSPanel) }
        guard !workspace.isEmpty else { return true }
        // Any one of them on screen is enough: a second workspace window counts as seeing the app.
        return !workspace.contains { !$0.isMiniaturized && $0.isVisible }
    }
}
