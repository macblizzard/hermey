import SwiftUI

#if os(iOS) && canImport(ActivityKit) && canImport(WidgetKit)
import ActivityKit
import WidgetKit

/// The two colours the card is allowed to use.
///
/// They are `Sources/HermeyUI/Theme.swift`'s tokens — `accent: 0xCC6543` and `canvas: 0xFAF9F5`
/// (`Theme.carbon`) — restated as literals because this file must not depend on `HermeyUI`: the
/// widget extension is its own process and its own target, and linking the design system (and the
/// package stack behind it) into it to read two integers is how an extension becomes slow to launch.
/// A second *palette* is what the brief forbids; these are the same two values, and there is no
/// third.
private enum HermeyTurnInk {
    static let accent = Color(.sRGB, red: 204 / 255, green: 101 / 255, blue: 67 / 255, opacity: 1)
    static let canvas = Color(.sRGB, red: 250 / 255, green: 249 / 255, blue: 245 / 255, opacity: 1)
    /// `Theme.carbon.ink`. The card pins a *light* canvas in both appearances, so its type cannot be
    /// `.primary`: on a dark-mode phone that is white on near-white paper, and the card reads as
    /// empty. Pinning ink is what keeps a light card legible at night.
    static let ink = Color(.sRGB, red: 20 / 255, green: 20 / 255, blue: 19 / 255, opacity: 1)
    static let inkSoft = Color(.sRGB, red: 20 / 255, green: 20 / 255, blue: 19 / 255, opacity: 0.62)
}

/// Where a piece is being drawn. The two surfaces do not share a text colour, and borrowing one for
/// the other is invisible in code and unreadable on the phone: the lock-screen card is pinned to the
/// light canvas, while the Dynamic Island is near-black in *both* appearances, so ink on it is dark
/// on dark. The accent is the one colour that works on either.
private enum HermeyTurnTone {
    case card
    case island

    var primary: Color {
        switch self {
        case .card: return HermeyTurnInk.ink
        case .island: return Color.white
        }
    }

    var secondary: Color {
        switch self {
        case .card: return HermeyTurnInk.inkSoft
        case .island: return Color.white.opacity(0.72)
        }
    }
}

/// The extension's only widget. One turn, drawn in five places: the lock screen, and the Dynamic
/// Island's expanded, compact-leading, compact-trailing and minimal presentations.
///
/// Everything here is text and SF Symbols — no images, no remote assets, no measured layout. A Live
/// Activity is rendered by the system from a snapshot with a small memory budget, so the card has to
/// look right at every width the island picks, which a row of text and one glyph does.
@main
struct HermeyTurnLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HermeyTurnAttributes.self) { context in
            HermeyTurnLockScreen(state: context.state,
                                 botName: context.attributes.botName,
                                 isStale: context.isStale)
                .activityBackgroundTint(HermeyTurnInk.canvas)
                .activitySystemActionForegroundColor(HermeyTurnInk.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                // Leading: the app's mark, so the island says *Hermey* before it says anything else.
                DynamicIslandExpandedRegion(.leading) {
                    HermeyTurnMark(phase: context.state.phase)
                        .padding(.leading, 4)
                }
                // Centre: the one line worth reading — which bot has the message.
                DynamicIslandExpandedRegion(.center) {
                    // No explicit colour: the island's own primary (white) is the legible one.
                    Text(context.attributes.botName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                // Trailing: elapsed while working, a tick once the reply has landed.
                DynamicIslandExpandedRegion(.trailing) {
                    HermeyTurnClock(state: context.state, tone: .island)
                        .padding(.trailing, 4)
                }
                // Bottom: the state in words, plus what the tick/timer means.
                DynamicIslandExpandedRegion(.bottom) {
                    HermeyTurnStatusLine(state: context.state,
                                         botName: context.attributes.botName,
                                         isStale: context.isStale,
                                         tone: .island)
                        .padding(.top, 2)
                }
            } compactLeading: {
                HermeyTurnMark(phase: context.state.phase, size: 15)
            } compactTrailing: {
                HermeyTurnClock(state: context.state, compact: true, tone: .island)
            } minimal: {
                // Minimal is the glyph only: the island leaves room for nothing else, and the
                // symbol already carries the state (working vs. tick).
                HermeyTurnMark(phase: context.state.phase, size: 15)
            }
            .keylineTint(HermeyTurnInk.accent)
        }
    }
}

// MARK: - Pieces

/// The app's mark for a turn: an "in progress" bubble while the bot works, a tick when it is done.
///
/// Both symbol names have shipped since iOS 13/15, so neither can resolve to the blank box a
/// missing SF Symbol draws. They are the only two glyphs in the feature.
private struct HermeyTurnMark: View {
    let phase: HermeyTurnAttributes.ContentState.Phase
    var size: CGFloat = 17

    var body: some View {
        Image(systemName: phase == .working ? "ellipsis.bubble" : "checkmark.circle")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(HermeyTurnInk.accent)
            .accessibilityHidden(true)
    }
}

/// Elapsed time while the turn runs, a tick when it is over.
///
/// `Text(_, style: .timer)` is the cheap half of "show elapsed": the system advances it between app
/// updates, so the app sends one update per turn rather than one per second. In compact trailing the
/// timer is the only thing shown, which is why it stays at caption size — the island clips, it does
/// not shrink.
private struct HermeyTurnClock: View {
    let state: HermeyTurnAttributes.ContentState
    var compact: Bool = false
    var tone: HermeyTurnTone = .card

    var body: some View {
        Group {
            if state.phase == .working {
                Text(state.startedAt, style: .timer)
                    .monospacedDigit()
                    .font(compact ? .caption2 : .caption)
                    .fontWeight(.medium)
                    .foregroundStyle(compact ? tone.primary : tone.secondary)
                    .lineLimit(1)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: compact ? 12 : 13, weight: .bold))
                    .foregroundStyle(HermeyTurnInk.accent)
            }
        }
    }
}

/// The state in words. Staleness is not an error: it means the app has not been able to update the
/// card (it was killed, or the turn is taking longer than the app promised), so the sentence steps
/// back to what is still true instead of claiming work that may have stopped.
private struct HermeyTurnStatusLine: View {
    let state: HermeyTurnAttributes.ContentState
    let botName: String
    let isStale: Bool
    var tone: HermeyTurnTone = .card

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(isStale ? tone.secondary : HermeyTurnInk.accent)
            Text(line)
                .font(.caption2)
                .foregroundStyle(tone.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        if state.phase == .done { return "checkmark.circle.fill" }
        return isStale ? "clock" : "circle.dotted"
    }

    private var line: String {
        switch state.phase {
        case .done:
            return "Replied"
        case .working:
            // "on your message" is the owner's own wording, and it is what tells him the turn is
            // *his* rather than some background sweep.
            return isStale ? "Still waiting on \(botName)" : "Working on your message"
        }
    }
}

/// The lock-screen row: mark, brand, bot, state.
///
/// It is the same content as the expanded island, laid out one line taller because the lock screen
/// gives it a full card's width. `Hermey` is spelled out here — the card's job is to be identifiable
/// at a glance on a screen with several notifications on it.
private struct HermeyTurnLockScreen: View {
    let state: HermeyTurnAttributes.ContentState
    let botName: String
    let isStale: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HermeyTurnMark(phase: state.phase, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // Text-only modifiers first, then the View ones: `kerning` exists on `Text`
                    // and not on the `some View` that `textCase` hands back.
                    Text("Hermey")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .kerning(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(HermeyTurnInk.inkSoft)
                    Text(botName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .foregroundStyle(HermeyTurnInk.ink)
                }
                HermeyTurnStatusLine(state: state, botName: botName, isStale: isStale, tone: .card)
            }
            Spacer(minLength: 8)
            HermeyTurnClock(state: state)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLine)
    }

    private var accessibilityLine: String {
        switch state.phase {
        case .done: return "Hermey. \(botName) replied."
        case .working: return isStale ? "Hermey. Still waiting on \(botName)."
                                     : "Hermey. \(botName) is working on your message."
        }
    }
}
#endif
