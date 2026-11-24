# The window language

Every menu, sheet and panel in both apps is drawn with the same three things: the canvas behind it,
the app's own (dark) appearance, and the same corner radius as a card. Before 2026-11-15 each sheet
chose for itself, so one app could show a black sheet next to a grey one with square corners — the
owner's report was "fix the windows for all menu items for macOS and iOS so that they all seem
harmonious to the apps design elements and themes".

## The rule

Apply `.hermesSheetChrome()` where the sheet is **presented**, not inside the sheet:

```swift
.sheet(isPresented: $showManageBots) {
    ManageBotsSheet(...)
        .hermesSheetChrome()
}
```

It is defined once, in `Sources/HermeyUI/SheetLanguage.swift`, and does exactly three things:

| What | Why |
|---|---|
| `Tokens.canvas` behind the sheet, ignoring the safe area | a short sheet is a card on the page, not a pale rectangle on a dark one |
| `.preferredColorScheme(.dark)` | Hermey is a dark product; following the system is what made two sheets disagree inside one window |
| `Tokens.radiusGrouped` + a matching presentation background (iOS) | the corners are cut out of the system's grey otherwise |

Detents, sizes, titles and close buttons stay with each sheet: those are *what* it is, not how it
looks. `popover` is deliberately not covered — a popover is a menu hanging off a control, and it
inherits the window's appearance by design.

## Every presentation site

Generated from the source (`Apps/**`), so the table cannot drift from the code. **Chrome** is
whether the site applies the rule.

| App | File | Line | Kind | Presented view | Chrome |
|---|---|---|---|---|---|
| HermesMac | `TranscriptRowView.swift` | 220 | sheet | `ImageViewer(data: item.data, title: item.name, canEx` | yes |
| HermesMac | `TranscriptScroll.swift` | 87 | sheet | `SelectTextSheet(text: selectionText ?? "") { selecti` | yes |
| HermesMac | `TranscriptScroll.swift` | 92 | sheet | `set: { if !$0 { pairPeer = "" } }))` | yes |
| HermesMac | `BotSidebarView.swift` | 71 | sheet | `AddBotSheet { name, description, face in` | yes |
| HermesMac | `BotSidebarView.swift` | 79 | sheet | `StartGroupChatSheet(` | yes |
| HermesMac | `BotSidebarView.swift` | 90 | sheet | `GroupChatsSheet(` | yes |
| HermesMac | `BotSidebarView.swift` | 97 | sheet | `ManageBotsSheet(` | yes |
| HermesMac | `AboutSettingsTab.swift` | 109 | sheet | `ClientLogView(title: "Log", header: logHeader)` | yes |
| HermesMac | `MacBotSettingsSheet.swift` | 89 | sheet | `BotMemorySheet(botName: bot.displayName,` | yes |
| HermesMac | `MacBotSettingsSheet.swift` | 94 | sheet | `SoulEditorSheet(` | yes |
| HermesMac | `MacSettingsView.swift` | 60 | sheet | `MacBotSettingsSheet(model: store.model,` | yes |
| HermesMac | `WorkspaceRoot.swift` | 134 | sheet | `switch route` | yes |
| HermesMobile | `HermesMobileApp.swift` | 60 | sheet | `PairingSheet()` | yes |
| HermesMobile | `BotListScreen.swift` | 228 | sheet | `settingsSheet(for: bot)` | yes |
| HermesMobile | `BotListScreen.swift` | 232 | sheet | `AddBotSheet { name, description, face in` | yes |
| HermesMobile | `BotListScreen.swift` | 240 | sheet | `SettingsScreen(model: model)` | yes |
| HermesMobile | `BotListScreen.swift` | 244 | sheet | `StartGroupChatSheet(` | yes |
| HermesMobile | `BotListScreen.swift` | 255 | sheet | `GroupChatsSheet(` | yes |
| HermesMobile | `BotListScreen.swift` | 262 | full screen | `RoomChatView(` | yes |
| HermesMobile | `BotListScreen.swift` | 278 | sheet | `ManageBotsSheet(` | yes |
| HermesMobile | `BotListScreen.swift` | 295 | sheet | `SoulEditorSheet(` | yes |
| HermesMobile | `BotModelSettingsScreen.swift` | 245 | sheet | `BotIconPicker(botName: bot.displayName, selected: ic` | yes |
| HermesMobile | `BotModelSettingsScreen.swift` | 265 | sheet | `BotMemorySheet(botName: bot.displayName, load: loadM` | yes |
| HermesMobile | `ConversationScreen.swift` | 278 | sheet | `WorkspaceSheet(bot: bot, client: app.workspace)` | yes |
| HermesMobile | `ConversationScreen.swift` | 282 | sheet | `BotToolsSheet(bot: bot, kind: .skills, model: model)` | yes |
| HermesMobile | `ConversationScreen.swift` | 286 | sheet | `BotToolsSheet(bot: bot, kind: .mcp, model: model)` | yes |
| HermesMobile | `ConversationScreen.swift` | 294 | sheet | `BotNotesSheet(botName: bot.displayName,` | yes |
| HermesMobile | `ConversationScreen.swift` | 300 | sheet | `SoulEditorSheet(` | yes |
| HermesMobile | `ConversationScreen.swift` | 307 | sheet | `BotMemorySheet(botName: bot.displayName,` | yes |
| HermesMobile | `ConversationScreen.swift` | 314 | sheet | `BotRoutinesSheet(` | yes |
| HermesMobile | `ConversationScreen.swift` | 323 | full screen | `BotComputerPane(profile: bot.id,` | yes |
| HermesMobile | `ConversationScreen.swift` | 331 | sheet | `BotModelSettingsScreen(` | yes |
| HermesMobile | `ConversationScreen.swift` | 355 | sheet | `switch source` | yes |
| HermesMobile | `ConversationScreen.swift` | 369 | sheet | `MobileApprovalSheet(model: model, request: model.pen` | yes |
| HermesMobile | `MobileApproval.swift` | 370 | sheet | `MobileApprovalSheet(model: AppModel(client: PreviewG` | yes |
| HermesMobile | `MobileTranscript.swift` | 120 | full screen | `ImageViewer(data: item.data, title: item.name, canEx` | yes |
| HermesMobile | `MobileTranscript.swift` | 125 | sheet | `set: { pairPeer = $0?.id })) { peer in` | yes |
| HermesMobile | `MobileTranscript.swift` | 136 | sheet | `NavigationStack` | yes |
| HermesMobile | `PairingSheet.swift` | 264 | sheet | `PairingSheet()` | yes |
| HermesMobile | `SettingsScreen.swift` | 181 | sheet | `ClientLogView(title: "Log", header: logHeader)` | yes |
| HermesMobile | `WorkspaceSheet.swift` | 97 | sheet | `ActivityShareSheet(url: item.url)` | yes |
| HermesMobile | `WorkspaceSheet.swift` | 243 | sheet | `ActivityShareSheet(url: item.url)` | yes |

43 presentation sites, 43 with the house chrome.

Nothing is left out.
