import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// Which bot's overflow menu is open, or was asked for.
///
/// A menu bar command cannot open a `Menu`: the only door SwiftUI gives a `Button` in `Commands`
/// is a callback, and a context menu cannot be raised from code either. So ⌘E and the row's ⋯
/// button both write the bot's id here and the *row* draws the popover — one menu, two doors, and
/// the anchor is the row the menu is about rather than the middle of the window.
///
/// It is a singleton because the caller is the app's menu bar (owned by `HermesMacApp`) and the
/// listener is a row deep inside the sidebar; neither owns the other.
@MainActor
final class BotMenuRouter: ObservableObject {
    static let shared = BotMenuRouter()

    /// The bot whose overflow menu should be showing.
    @Published private(set) var botID: String?

    /// The sidebar header's **+** menu asked for the category prompt. The sheet belongs to the
    /// list — it already owns two presentations, and a third `.sheet` on the header would fight
    /// them — so the request travels here instead of being duplicated up the tree.
    @Published private(set) var wantsNewCategory = false

    private init() {}

    func requestNewCategory() { wantsNewCategory = true }

    func acknowledgeNewCategory() { wantsNewCategory = false }

    /// Open on this bot, or close it when it is already open there.
    ///
    /// Both doors toggle, so ⌘E twice is open-then-closed rather than a key that only ever opens
    /// and has to be undone with the pointer.
    func toggle(botID: String) {
        self.botID = (self.botID == botID) ? nil : botID
    }

    func close(botID: String) {
        if self.botID == botID { self.botID = nil }
    }

    func close() { botID = nil }
}

// MARK: - The menu, as data

/// Everything a bot's row menu can do, in one value.
///
/// Two renderers read it — the native `contextMenu` (right-click, and the trackpad's long press)
/// and the popover the ⋯ and ⌘E open — so the entries cannot drift apart, and every verb lands on
/// the same store or model call whichever door was used.
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

// MARK: - The native menu (right-click, long press)

/// The row's context menu. `Group` is what makes one description work in two containers: a menu
/// flattens it into items, the popover stacks them.
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

// MARK: - The popover (⋯ and ⌘E)

/// The same menu, drawn as a panel.
///
/// A popover rather than a `Menu` because ⌘E cannot open a `Menu` — see `BotMenuRouter` — and
/// having the dots open one thing while the key opened another would be two menus that disagree.
/// Rows are 26 pt, the fill is the panel's one hover signal, and the whole thing is 236 pt wide:
/// a menu, not a sheet.
struct BotOverflowPanel: View {
    let menu: BotMenu
    var onClose: () -> Void = {}

    @State private var hoveredID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header

            row("settings", "Bot Settings", icon: "gearshape", run: menu.openSettings)
            row("pin",
                menu.isPinned ? "Unpin" : "Pin to top",
                icon: menu.isPinned ? "pin.slash" : "pin",
                run: menu.togglePin)

            rule

            SectionCaption("CATEGORY")
                .padding(.horizontal, 8)
                .padding(.bottom, 2)

            categoryRows

            rule

            row("sessions", "All sessions…", icon: "clock.arrow.circlepath", run: menu.showSessions)

            rule

            row("hide",
                menu.isHidden ? "Show bot" : "Hide bot",
                icon: menu.isHidden ? "eye" : "eye.slash",
                tone: Tokens.danger,
                run: menu.toggleHidden)
        }
        .padding(6)
        .frame(width: 236)
        .background(Tokens.surface)
    }

    private var header: some View {
        HStack(spacing: 8) {
            BotIconPortrait(menu.face, size: 22)

            VStack(alignment: .leading, spacing: 0) {
                Text(menu.bot.displayName)
                    .font(TypeScale.font(TypeScale.caption, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                Text(menu.bot.id)
                    .font(TypeScale.font(TypeScale.micro))
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private var rule: some View {
        Divider().padding(.vertical, 5)
    }

    @ViewBuilder
    private var categoryRows: some View {
        ForEach(menu.categories) { category in
            let isCurrent = menu.currentCategoryID == category.id
            row("cat-\(category.id)",
                category.name,
                icon: isCurrent ? "checkmark.circle.fill" : "circle",
                tone: isCurrent ? Tokens.accentText : Tokens.textPrimary,
                run: { menu.assignCategory(category.id) })
                // Renaming and deleting live on the group heading too; here they are one
                // right-click away from the group the bot is in, which is where the thought
                // "this is the wrong name" happens.
                .contextMenu {
                    Button { menu.renameCategory(category) } label: {
                        Label("Rename “\(category.name)”…", systemImage: "pencil")
                    }
                    Button(role: .destructive) { menu.deleteCategory(category) } label: {
                        Label("Delete “\(category.name)”", systemImage: "trash")
                    }
                }
        }

        if menu.categories.isEmpty {
            Text("No categories yet")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }

        row("cat-new", "New category…", icon: "folder.badge.plus", run: menu.newCategory)
        row("cat-none",
            "Remove from category",
            icon: "folder.badge.minus",
            isDisabled: menu.currentCategoryID == nil,
            run: { menu.assignCategory(nil) })
    }

    /// One line of the menu: 16 pt glyph, 26 pt tall, hover fill only — nothing here changes size,
    /// so the menu never jumps under the pointer.
    private func row(_ id: String,
                     _ title: String,
                     icon: String,
                     tone: Color = Tokens.textPrimary,
                     isDisabled: Bool = false,
                     run: @escaping () -> Void) -> some View {
        // A menu item closes the menu. The actions that open a sheet set their state first and
        // this dismissal lands after it, which is the order the sheet needs.
        Button {
            run()
            onClose()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isDisabled ? Tokens.textDim : tone)
                    .frame(width: 16, alignment: .center)

                Text(title)
                    .font(TypeScale.font(TypeScale.md))
                    .foregroundStyle(isDisabled ? Tokens.textDim : tone)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                    .fill(hoveredID == id && !isDisabled ? Tokens.controlHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { inside in
            if inside { hoveredID = id }
            else if hoveredID == id { hoveredID = nil }
        }
        .help(title)
    }
}

#if DEBUG
private struct BotOverflowPanelPreview: View {
    var body: some View {
        BotOverflowPanel(menu: BotMenu(
            bot: Bot(id: "assistant", displayName: "Assistant", description: "Everything else"),
            face: BotFace.default(for: "assistant"),
            isPinned: true,
            isHidden: false,
            categories: [BotCategory(id: "work", name: "Work"),
                         BotCategory(id: "home", name: "Home")],
            currentCategoryID: "work",
            openSettings: {},
            togglePin: {},
            toggleHidden: {},
            showSessions: {},
            assignCategory: { _ in },
            newCategory: {},
            renameCategory: { _ in },
            deleteCategory: { _ in }))
        .preferredColorScheme(.dark)
    }
}

#Preview("Bot menu") {
    BotOverflowPanelPreview()
}
#endif
