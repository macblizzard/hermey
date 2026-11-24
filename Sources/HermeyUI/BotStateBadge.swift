import HermesKit
import SwiftUI

/// One bot state, drawn as its word.
///
/// This is the badge the roster rows wear while a bot is doing something, and the one the desktop
/// pet shows under its face. **It never writes a word itself**: the text is
/// `BotAvatarActivity.label`, which is `BotStateWord` — the same table the Live Activity reads — so
/// a row, a pet and a lock screen cannot end up with three vocabularies for one bot.
///
/// `.idle` draws nothing: an idle bot is a legend, and a chip saying Idle on every quiet row is
/// noise. Every other state is worth a word.
public struct BotStateBadge: View {
    public var activity: BotAvatarActivity
    /// The word's point size. The roster passes its row metrics; the pet is smaller than a row.
    public var size: CGFloat

    public init(activity: BotAvatarActivity, size: CGFloat = 9) {
        self.activity = activity
        self.size = size
    }

    /// Waiting and blocked are the two states that want the owner; done is history. The tone says
    /// which of those this is without a second badge or a colour map at the call site.
    private var tone: Color {
        switch activity {
        case .waiting: return Tokens.warning
        case .blocked: return Tokens.danger
        case .done: return Tokens.textMuted
        case .idle, .thinking, .reading, .working, .computer: return Tokens.accent
        }
    }

    public var body: some View {
        if activity == .idle {
            EmptyView()
        } else {
            Text(activity.label)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundStyle(tone)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(activity.label)
        }
    }
}
