import HermesRender
import OpenBotUI

/// Chat metrics at the user's chosen text size.
///
/// `ChatTextMetrics.macOS` is a constant (14 pt on a 1.62 line), and the transcript passed it
/// straight through: ⌘+ moved the bot list, the header and the composer while the conversation —
/// the text the setting exists for — stayed put. The renderer only needs numbers, so the numbers
/// come from `TypeScale`.
public extension ChatTextMetrics {
    static var macOSScaled: ChatTextMetrics {
        ChatTextMetrics(platform: .macOS, bodySize: TypeScale.chatBody, bodyLineHeight: TypeScale.chatLine)
    }

    static var iOSScaled: ChatTextMetrics {
        ChatTextMetrics(platform: .iOS, bodySize: TypeScale.chatBody, bodyLineHeight: TypeScale.chatLine)
    }
}
