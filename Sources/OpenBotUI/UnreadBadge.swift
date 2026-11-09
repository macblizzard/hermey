import SwiftUI

/// How many turns a bot wrote while you were not looking, drawn as a small capsule on the corner of
/// its face.
///
/// It sits on the avatar rather than at the end of the row because the number belongs to the bot, not
/// to the row's chrome — and because the beacon already owns the trailing edge: the beacon says
/// *something* is waiting, the badge says *how much*. They are meant to be seen together.
///
/// Three rules, each of them a mistake the first draft made cheap to avoid:
///
/// * **Zero draws nothing.** A badge reading `0` is a worse statement than no badge.
/// * **The number never changes the layout.** The capsule grows around its text and is clipped at
///   `99+`, so a bot with three digits cannot push the avatar or the row's title sideways.
/// * **It is announced once.** The avatar's accessibility label already carries the bot's name; the
///   badge contributes "N unread" to it instead of becoming a separate element a screen reader has
///   to stop on.
public struct UnreadBadge: View {
    private let count: Int
    private let size: CGFloat

    public init(count: Int, size: CGFloat = 18) {
        self.count = count
        self.size = size
    }

    public var body: some View {
        if count > 0 {
            Text(text)
                .font(.system(size: size * 0.62, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Tokens.canvas)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, count > 9 ? size * 0.28 : 0)
                .frame(minWidth: size, minHeight: size)
                .background(
                    Capsule().fill(Tokens.success)
                        .overlay(Capsule().strokeBorder(Tokens.canvas, lineWidth: size * 0.12))
                )
                .accessibilityLabel("\(count) unread")
        }
    }

    /// `99+` past two digits: the exact number stops being useful before the bubble stops growing.
    private var text: String { count > 99 ? "99+" : String(count) }
}

#if DEBUG
#Preview("Unread badge") {
    HStack(spacing: 16) {
        UnreadBadge(count: 1)
        UnreadBadge(count: 2)
        UnreadBadge(count: 12)
        UnreadBadge(count: 340)
        UnreadBadge(count: 0)
    }
    .padding()
    .background(Tokens.surface)
}
#endif
