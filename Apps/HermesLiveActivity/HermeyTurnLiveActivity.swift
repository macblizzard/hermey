import Foundation
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
/// look right at every width the island picks.
///
/// **The compact presentations own no width.** This is the rule the shipped 0.1.618 card broke: the
/// island sizes itself from what its compact slots *report*, so any view there that accepts the
/// proposed width and hands it back — a `Spacer()`, `.frame(maxWidth: .infinity)`, or, as it was, a
/// plain `Text` measuring against the full proposal — widens the pill until it runs under the status
/// bar's clock and battery. Every compact view here is therefore pinned with `.fixedSize()`, which
/// reports intrinsic size and ignores the proposal, and the bot's name is shortened in code before
/// it reaches the `Text` so intrinsic size is small by construction.
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
                // Trailing: elapsed while working, the elapsed total once the reply has landed.
                DynamicIslandExpandedRegion(.trailing) {
                    HermeyTurnClock(state: context.state, tone: .island)
                        .padding(.trailing, 4)
                }
                // Bottom: the state in words, plus what the tick/timer means — and, once the turn
                // is over, the first line of what the bot actually said.
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        HermeyTurnStatusLine(state: context.state,
                                             botName: context.attributes.botName,
                                             isStale: context.isStale,
                                             tone: .island)
                        HermeyTurnSnippet(state: context.state, tone: .island)
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                // A glyph and a handful of letters: enough to answer "which bot" at a glance,
                // small enough that the island keeps the status bar to itself.
                HermeyTurnCompactLead(phase: context.state.phase,
                                      botName: context.attributes.botName)
            } compactTrailing: {
                HermeyTurnClock(state: context.state, compact: true, tone: .island)
            } minimal: {
                // Minimal is the glyph only: the island leaves room for nothing else, and the
                // symbol already carries the state (working vs. done).
                HermeyTurnMark(phase: context.state.phase, size: 15)
                    .fixedSize()
            }
            .keylineTint(HermeyTurnInk.accent)
        }
    }
}

// MARK: - Pieces

/// The names the card is allowed to print.
///
/// `botName` is a display string the owner chose, and it can be a sentence ("Research assistant, EU
/// policy"). The island's compact slot is roughly the width of a clock face, so the name is cut to
/// `compactLimit` characters *here*, in code, rather than left to `lineLimit`, which would still ask
/// the layout for the whole string's width before truncating what it draws.
private enum HermeyTurnNames {
    static let compactLimit = 8

    static func compact(_ name: String) -> String {
        let tidy = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !tidy.isEmpty else { return "" }
        guard tidy.count > compactLimit else { return tidy }
        return String(tidy.prefix(compactLimit)) + "…"
    }
}

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
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// What the island's compact leading slot shows: the mark, then as much of the bot's name as fits.
///
/// It is `.fixedSize()` on the `HStack` and not just on the pieces: a compact slot is offered the
/// full compact width, and a stack that accepts it is a stack that stretches the pill. Pinning the
/// stack to its ideal size is what keeps the island at the width of its notch plus a few letters.
private struct HermeyTurnCompactLead: View {
    let phase: HermeyTurnAttributes.ContentState.Phase
    let botName: String

    var body: some View {
        HStack(spacing: 3) {
            HermeyTurnMark(phase: phase, size: 13)
            let label = HermeyTurnNames.compact(botName)
            if !label.isEmpty {
                Text(label)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .foregroundStyle(Color.white)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(botName)
    }
}

/// Elapsed time while the turn runs, the elapsed total when it is over.
///
/// `Text(_, style: .timer)` is the cheap half of "show elapsed": the system advances it between app
/// updates, so the app sends one update per turn rather than one per second.
///
/// The timer text is `.fixedSize(horizontal: true, vertical: false)` and that modifier is the fix,
/// not decoration. A `Text` fills whatever width it is offered, and in a compact slot it is offered
/// the whole compact width; the island then sizes itself around that number. Pinning the text to its
/// ideal width — a handful of monospaced digits — is what stops the pill widening to two-thirds of
/// the screen. `.monospacedDigit()` keeps that ideal width constant as the digits change, so the
/// island does not twitch every second.
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
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                // The elapsed total, frozen. A live timer would keep counting past the end of the
                // turn, which says the bot is still working; the number is what actually happened.
                Text(HermeyTurnElapsed.short(from: state.startedAt, to: state.finishedAt ?? state.startedAt))
                    .monospacedDigit()
                    .font(compact ? .caption2 : .caption)
                    .fontWeight(.medium)
                    .foregroundStyle(compact ? tone.primary : tone.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

/// A duration as the timer style would have written it: `1:06`, or `1:02:03` past the hour.
private enum HermeyTurnElapsed {
    static func short(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start).rounded(.down)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
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

/// The first line or two of the reply, when there is one.
///
/// It draws *nothing* while the turn runs or when the coordinator had no text: an empty snippet is
/// an honest "no reply yet", while a placeholder ("Working…") would be a second status line saying
/// what the one above it already says. `state.replySnippet` is already flattened and capped by the
/// attributes type, so the only job here is the two-line limit.
private struct HermeyTurnSnippet: View {
    let state: HermeyTurnAttributes.ContentState
    var tone: HermeyTurnTone = .card

    var body: some View {
        let snippet = state.replySnippet
        if state.phase == .done, !snippet.isEmpty {
            Text(snippet)
                .font(.caption2)
                .foregroundStyle(tone.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .accessibilityLabel("Reply: \(snippet)")
        }
    }
}

/// The lock-screen row: mark, brand, bot, state, and the reply's first line.
///
/// It is the same content as the expanded island, laid out a line taller because the lock screen
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
                HermeyTurnSnippet(state: state, tone: .card)
            }
            Spacer(minLength: 8)
            HermeyTurnClock(state: state)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLine)
    }

    /// The snippet is read after the sentence rather than as a separate element: VoiceOver announces
    /// the card as one thing, and the words of the reply are the reason the owner raised his phone.
    private var accessibilityLine: String {
        let snippet = state.replySnippet
        let said = snippet.isEmpty ? "" : " \(snippet)"
        switch state.phase {
        case .done: return "Hermey. \(botName) replied.\(said)"
        case .working: return isStale ? "Hermey. Still waiting on \(botName)."
                                     : "Hermey. \(botName) is working on your message."
        }
    }
}
#endif
