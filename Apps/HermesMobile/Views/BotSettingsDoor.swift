import HermesAppKit
import HermesKit
import HermeyUI
import SwiftUI

/// One bot's settings, from either door.
///
/// The bot list reaches it by long-pressing a row; a conversation reaches it by opening the drawer and
/// tapping Edit. They are the same sheet answering the same question, so they are one view: before this
/// existed the conversation's copy was built separately and had quietly lost whole sections — the
/// avatar editor, the soul editor and the memory pane were simply absent there, which is exactly what
/// "the edit button lacks some settings like bot image edit, soul, etc." described (reported 2026-11-17).
///
/// It owns the soul sheet itself, because that is the one section that is a second presentation rather
/// than a pane, and a caller that had to remember to add it is how the two doors drifted apart.
struct BotSettingsDoor: View {
    let bot: Bot
    @ObservedObject var model: AppModel
    @EnvironmentObject private var app: AppEnvironment

    @State private var soulBot: Bot?

    var body: some View {
        BotModelSettingsScreen(
            bot: bot,
            icon: app.botFaces[bot.id],
            // The model, effort and aux/vision live in `BotModelSheet` now, reached from the drawer's
            // Model row — the desktop's arrangement (asked for 2026-11-17).
            saveDescription: { botID, text in
                try await model.configureDescription(botID: botID, description: text)
            },
            editSoul: { soulBot = bot },
            loadMemory: { try await model.memory(for: bot.id) },
            deleteBot: { try await model.deleteBot(bot.id) },
            avatar: app.botAvatars[bot.id],
            saveAvatar: { document in try await app.saveBotAvatar(botID: bot.id, document: document) })
        .sheet(item: $soulBot) { bot in
            SoulEditorSheet(
                botName: bot.displayName,
                load: { try await model.describeBot(bot.id).soul },
                save: { try await model.saveSoul($0, for: bot.id) })
            .hermesSheetChrome()
        }
    }
}
