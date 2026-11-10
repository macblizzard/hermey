import SwiftUI

/// The little reactions a message can wear, in one place.
///
/// Both shells show the same six, in the same order, so a reaction means the same thing on the
/// desktop as on the phone — and so a picker never has to be a submenu of a menu of a long press.
public enum ReactionEmoji {
    public static let basic = ["👍", "❤️", "😂", "😮", "😢", "🎉"]

    /// What to call each one out loud and in a tooltip — an emoji alone is not a label.
    public static func name(_ emoji: String) -> String {
        switch emoji {
        case "👍": return "Thumbs Up"
        case "❤️": return "Heart"
        case "😂": return "Laughing"
        case "😮": return "Surprised"
        case "😢": return "Sad"
        case "🎉": return "Celebrate"
        default: return "React"
        }
    }
}

/// One horizontal row of the basic reactions, with the chosen one ringed.
///
/// A row, not a grid and not a page: six emoji is a gesture's worth of choice, and putting them on
/// the surface that already appeared saves the "Add reaction" step that made the menu two menus.
public struct QuickReactionRow: View {
    /// The emoji already on this message, if any. Drawn in a ring; tapping it removes it.
    public var selected: String?
    public var onPick: (String) -> Void
    /// Emoji size. The row is sized from it, so a caller does not have to know the paddings.
    public var emojiSize: CGFloat

    public init(selected: String?, emojiSize: CGFloat = 21, onPick: @escaping (String) -> Void) {
        self.selected = selected
        self.emojiSize = emojiSize
        self.onPick = onPick
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(ReactionEmoji.basic, id: \.self) { emoji in
                Button { onPick(emoji) } label: {
                    Text(emoji)
                        .font(.system(size: emojiSize))
                        .frame(width: emojiSize + 15, height: emojiSize + 13)
                        .background(
                            Circle()
                                .fill(selected == emoji ? Tokens.accentSoft : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // A popover hands focus to its first control, and the focus ring drew a square
                // around 👍 — a ring on a bare emoji reads as a selection, which it is not.
                .focusable(false)
                .focusEffectDisabled()
                .help(ReactionEmoji.name(emoji))
                .accessibilityLabel(ReactionEmoji.name(emoji))
                .accessibilityHint(selected == emoji ? "Select again to remove this reaction"
                                                     : "React with \(emoji)")
            }
        }
        .fixedSize()
    }
}
