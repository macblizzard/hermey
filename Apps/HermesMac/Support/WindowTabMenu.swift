import AppKit

/// The View menu, minus the window-tabbing items AppKit adds on its own.
///
/// Hermey has one window per scene and no tabs, so "Show Tab Bar", "Show All Tabs", "Move Tab to
/// New Window" and their siblings were items that could not do anything — and they sat above the
/// text-size entries the owner actually uses. The real fix is the process-wide switch in
/// `HermesMacApp.init` (`NSWindow.allowsAutomaticWindowTabbing = false`, set before any window
/// exists); this sweep is the belt for a build where the switch came too late and AppKit had
/// already inserted the items.
///
/// It touches nothing else: only items whose *action* is one of the automatic tabbing selectors, or
/// whose title is one of the two the owner saw. The text-size commands and the full-screen item are
/// untouched, and an app that never grew these items sees nothing happen.
@MainActor
enum WindowTabMenu {
    /// AppKit's own selectors for the automatic items. Matched by selector rather than by title so a
    /// localised build is cleaned too; the titles below are only a backstop.
    private static let tabbingSelectors: Set<String> = [
        "toggleTabBar:",
        "toggleTabBarIfNeeded:",
        "selectNextTab:",
        "selectPreviousTab:",
        "selectNextTabInWindow:",
        "selectPreviousTabInWindow:",
        "moveTabToNewWindow:",
        "mergeAllWindows:",
        "showAllTabs:",
    ]

    private static let tabbingTitles: Set<String> = ["Show Tab Bar", "Show All Tabs"]

    /// Once per launch: the menu is built before the first window is shown and is not rebuilt.
    private static var purged = false

    static func purge() {
        guard !purged else { return }
        purged = true
        guard let main = NSApp.mainMenu,
              let view = main.items.first(where: { $0.submenu?.title == "View" })?.submenu
        else { return }
        // `items` is a snapshot: removable while the menu is being changed.
        for item in view.items where isTabbingItem(item) {
            view.removeItem(item)
        }
    }

    private static func isTabbingItem(_ item: NSMenuItem) -> Bool {
        guard !item.isSeparatorItem else { return false }
        if let action = item.action, tabbingSelectors.contains(NSStringFromSelector(action)) {
            return true
        }
        return tabbingTitles.contains(item.title)
    }
}
