import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// A request from the sidebar's header to the sidebar's list.
///
/// The header's **+** menu asks for the category prompt, and the sheet belongs to the list — it
/// already owns two presentations, and a third `.sheet` on the header would fight them — so the
/// request travels here instead of being duplicated up the tree.
///
/// It is a singleton because the caller (the header) and the listener (the list) do not own each
/// other.
///
/// It used to carry ⌘E as well: the key wrote a bot id here and the matching row drew a popover,
/// because a menu-bar button cannot raise a `Menu`. That popover was the wrong shape for the key —
/// ⌘E opens the bot's panel on the right edge now, the same panel the pill in the chat header opens,
/// and every verb that popover listed is a row in that panel. So the router has one job left.
@MainActor
final class BotMenuRouter: ObservableObject {
    static let shared = BotMenuRouter()

    /// The sidebar header's **+** menu asked for the category prompt.
    @Published private(set) var wantsNewCategory = false

    private init() {}

    func requestNewCategory() { wantsNewCategory = true }

    func acknowledgeNewCategory() { wantsNewCategory = false }
}

// MARK: - The menu, as data

/// Everything a bot's row menu can do, in one value.
///
/// One description, two containers: the row's `contextMenu` (right-click) and the `Menu` behind its
/// ⋯ open the same entries, so the two doors cannot drift apart and every verb lands on the same
/// store or model call whichever was used.
struct BotMenu {
    let bot: Bot
    let face: BotFace
    let isPinned: Bool
    let isHidden: Bool
    let categories: [BotCategory]
    let currentCategoryID: String?

    let openSettings: () -> Void
    let togglePin: () -> Void
    let toggleHidden: () -> Void
    let showSessions: () -> Void
    /// `nil` puts the bot back in Uncategorized.
    let assignCategory: (String?) -> Void
    let newCategory: () -> Void
    let renameCategory: (BotCategory) -> Void
    let deleteCategory: (BotCategory) -> Void
}

// MARK: - The native menu (right-click, and the row's ⋯)

/// The row's menu. `Group` is what makes one description work in two containers — the row's
/// `contextMenu` and the `Menu` behind its ⋯ — both native menus, so both flatten the group into
/// items and the entries cannot drift apart.
struct BotRowMenu: View {
    let menu: BotMenu

    var body: some View {
        Group {
            Button { menu.openSettings() } label: {
                Label("Bot Settings", systemImage: "gearshape")
            }

            Button { menu.togglePin() } label: {
                Label(menu.isPinned ? "Unpin" : "Pin to top",
                      systemImage: menu.isPinned ? "pin.slash" : "pin")
            }

            Divider()

            Menu {
                categoryItems
            } label: {
                Label("Category", systemImage: "folder")
            }

            Divider()

            Button { menu.showSessions() } label: {
                Label("All sessions…", systemImage: "clock.arrow.circlepath")
            }

            Divider()

            Button(role: .destructive) { menu.toggleHidden() } label: {
                Label(menu.isHidden ? "Show bot" : "Hide bot",
                      systemImage: menu.isHidden ? "eye" : "eye.slash")
            }
        }
    }

    /// The owner's groups, the current one ticked, then the two verbs that move a bot without
    /// opening a sheet. A host with no groups says so instead of offering an empty submenu.
    @ViewBuilder
    private var categoryItems: some View {
        if menu.categories.isEmpty {
            Text("No categories yet")
        }

        ForEach(menu.categories) { category in
            Button {
                menu.assignCategory(category.id)
            } label: {
                Label(menu.currentCategoryID == category.id
                      ? "✓ \(category.name)" : category.name,
                      systemImage: "folder")
            }
        }

        if !menu.categories.isEmpty { Divider() }

        Button { menu.newCategory() } label: {
            Label("New category…", systemImage: "folder.badge.plus")
        }

        Button { menu.assignCategory(nil) } label: {
            Label("Remove from category", systemImage: "folder.badge.minus")
        }
        .disabled(menu.currentCategoryID == nil)
    }
}

