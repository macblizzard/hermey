import Foundation
import SwiftUI

#if os(iOS) && canImport(ActivityKit) && canImport(WidgetKit)
import ActivityKit
import WidgetKit

/// The one colour this feature owns: `Theme.carbon`'s accent — `0xCC6543` — restated as a literal
/// because this file must not depend on `HermeyUI`: the widget extension is its own process and its
/// own target, and linking the design system (and the package stack behind it) into it to read one
/// integer is how an extension becomes slow to launch.
///
/// It is an **accent and nothing else**: the glyph that says working/done, the keyline, the system
/// action tint. There is no fill of ours any more. The card and the island are the system's own
/// surfaces — glass on the Lock Screen, black in the island — so every word on them is drawn in the
/// system's own ink (`primary`/`secondary`, or white where the island is black in both appearances).
/// The pale gold panel the owner screenshotted was `activityBackgroundTint(canvas)`: a pinned
/// light-paper fill that fought the glass and left the text with nothing to contrast against.
private enum HermeyTurnAccent {
    static let amber = Color(.sRGB, red: 204 / 255, green: 101 / 255, blue: 67 / 255, opacity: 1)
}

/// How much room the words get, and how much lift the glass gets.
///
/// The owner's report was that the text sat almost on the card's border and that the card read as a
/// solid slab rather than the Lock Screen's glass. Both are one number each: the card takes real
/// margins instead of the couple of points the system's default leaves at the corners, and the tint
/// is a whisper of white over the system's material — enough to see the wallpaper through it on a
/// dark photo, not enough to become a panel of its own.
private enum HermeyTurnGlass {
    /// Card content margins, horizontal and vertical.
    static let cardHorizontal: CGFloat = 8
    static let cardVertical: CGFloat = 8
    /// The island's leading/trailing regions, off the pill's rounded edge.
    static let islandInset: CGFloat = 8
    /// The white lift over the Lock Screen material. Not a fill: the blur still shows.
    static let lift: Double = 0.10
}

/// Where a piece is being drawn.
///
/// The two surfaces do not share an ink: the Lock Screen card is the system's glass, which is light
/// or dark with the device, so the card takes the system's own semantic colours; the Dynamic Island
/// is near-black in *both* appearances, where `primary`/`secondary` resolve outside the island's
/// contrast, so it is pinned to white. The accent is the one colour that works on either.
private enum HermeyTurnTone {
    case card
    case island

    var primary: Color {
        switch self {
        case .card: return .primary
        case .island: return Color.white
        }
    }

    var secondary: Color {
        switch self {
        case .card: return .secondary
        case .island: return Color.white.opacity(0.72)
        }
    }
}

/// The extension's only widget. One turn, drawn in five places: the Lock Screen, and the Dynamic
/// Island's expanded, compact-leading, compact-trailing and minimal presentations.
///
/// Everything here is text and SF Symbols — no images, no remote assets, no measured layout.
///
/// **A compact region owns no width.** The island sizes itself from what its compact slots
/// *report*, so anything there that accepts the proposal widens the pill until it runs under the
/// status bar's clock and battery. The rule is now enforced twice: every compact piece is
/// `.fixedSize()` at the outermost view of the region closure, and **no clock is a live timer**.
/// `Text(date, style: .timer)` is the one view that cannot be pinned — a timer has to be able to
/// render any elapsed value, so it takes the width it is offered and `.fixedSize(horizontal:)` pins
/// nothing. That was the 0.1.639 pill: three-quarters of the screen of black, the mark and the
/// bot's name packed at the leading edge, and the timer's claimed width filling the rest.
/// `HermeyTurnElapsed` formats the number instead, so the label's width is its digits.
///
/// **The card is the system's glass.** No `activityBackgroundTint`: the card's background is
/// whatever the Lock Screen draws, and the ink is `.primary`/`.secondary` so it is legible on it in
/// either appearance. The accent stays on the glyph and the status symbol.
@main
struct HermeyTurnLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HermeyTurnAttributes.self) { context in
            HermeyTurnLockScreen(state: context.state,
                                 botName: context.attributes.botName,
                                 isStale: context.isStale)
                // Glass, not a slab: the Lock Screen's own material stays, and a barely-there white
                // lift keeps it from reading as solid black over a dark wallpaper. It is a tint,
                // not a fill — the blur and the wallpaper still show through.
                .activityBackgroundTint(Color.white.opacity(HermeyTurnGlass.lift))
                .activitySystemActionForegroundColor(HermeyTurnAccent.amber)
        } dynamicIsland: { context in
            DynamicIsland {
                // Leading: the app's mark, so the island says *Hermey* before it says anything else.
                DynamicIslandExpandedRegion(.leading) {
                    HermeyTurnMark(phase: context.state.phase)
                        .padding(.leading, HermeyTurnGlass.islandInset)
                }
                // Centre: which bot has the message, and what it is doing — the step line belongs
                // here rather than in `.bottom`. The expanded island's floor is 84 pt, which fits
                // the name row; a second *region* while a turn merely runs is what collapsed the
                // pill into an empty black bar. Two lines in one region fit.
                DynamicIslandExpandedRegion(.center) {
                    HermeyTurnExpandedCenter(state: context.state,
                                             botName: context.attributes.botName,
                                             isStale: context.isStale)
                }
                // Trailing: the elapsed number, balanced against the mark on the left.
                DynamicIslandExpandedRegion(.trailing) {
                    HermeyTurnElapsedLabel(state: context.state, tone: .island)
                        .padding(.trailing, HermeyTurnGlass.islandInset)
                }
                // Bottom: the reply's first lines, and only once there is a reply to quote.
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.phase == .done {
                        HermeyTurnSnippet(state: context.state, tone: .island)
                            .padding(.top, 2)
                    }
                }
            } compactLeading: {
                // A glyph and a handful of letters: enough to answer "which bot" at a glance,
                // small enough that the island keeps the status bar to itself.
                HermeyTurnCompactLead(phase: context.state.phase,
                                      botName: context.attributes.botName)
                    .fixedSize()
            } compactTrailing: {
                // A few monospaced digits. Pinned at the region's outermost view, not only inside
                // the label, so the slot reports that and nothing wider.
                HermeyTurnElapsedLabel(state: context.state, tone: .island)
                    .fixedSize()
            } minimal: {
                // Minimal is the glyph only: the island leaves room for nothing else, and the
                // symbol already carries the state (working vs. done).
                HermeyTurnMark(phase: context.state.phase, size: 15)
                    .fixedSize()
            }
            .keylineTint(HermeyTurnAccent.amber)
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
/// missing SF Symbol draws. They are the only two glyphs in the feature, and the accent is the only
/// colour either of them takes.
private struct HermeyTurnMark: View {
    let phase: HermeyTurnAttributes.ContentState.Phase
    var size: CGFloat = 17

    var body: some View {
        Image(systemName: phase == .working ? "ellipsis.bubble" : "checkmark.circle")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(HermeyTurnAccent.amber)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// What the island's compact leading slot shows: the mark, then as much of the bot's name as fits.
///
/// It is `.fixedSize()` on the `HStack` and not just on the pieces: a compact slot is offered the
/// full compact width, and a stack that accepts it is a stack that stretches the pill. Pinning the
/// stack to its ideal size is what keeps the island at the width of its notch plus a few letters —
/// about 60–70 pt for a four-letter name at caption size.
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

/// How long the turn has run, as a formatted string: `1:06`, or `1:02:03` past the hour.
///
/// **Not `Text(_, style: .timer)`.** That style is the one view in this feature that cannot be told
/// its width: it must be able to render any elapsed value, so the layout gives it the width it was
/// offered, and `.fixedSize(horizontal:)` cannot pin a size the text does not have. In the compact
/// trailing slot it therefore widened the island to about 82% of the screen (the mark and the name
/// sat at the leading edge of a mostly empty pill), and on the Lock Screen the same view took the
/// row's whole width and squeezed the name and the step line to nothing — which is why the card was
/// a blank panel until the turn ended and a plain string was drawn in its place.
///
/// A formatted string has real digits, so its ideal width is its content. The app updates the card
/// when the step changes (thinking, a tool, streaming) and at the end, so the number is as fresh as
/// the last snapshot — and the *finished* card freezes at `finishedAt`, which is the honest total.
private struct HermeyTurnElapsedLabel: View {
    let state: HermeyTurnAttributes.ContentState
    var tone: HermeyTurnTone = .card

    var body: some View {
        let elapsed = HermeyTurnElapsed.short(from: state.startedAt,
                                             to: state.finishedAt ?? Date())
        Text(elapsed)
            .monospacedDigit()
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(tone.primary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Elapsed \(elapsed)")
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

/// The expanded island's centre: the bot's name over the line saying what it is doing.
///
/// The step lives here, next to the name, rather than in `.bottom`, because a *region* added while
/// a turn runs is what collapsed the expanded pill in 0.1.620 (the floor is 84 pt, one row). Two
/// caption lines inside one region fit.
private struct HermeyTurnExpandedCenter: View {
    let state: HermeyTurnAttributes.ContentState
    let botName: String
    let isStale: Bool

    var body: some View {
        // One line: the bot's name and what it is doing, side by side. Stacked, the shorter status
        // line hung off the name's left edge and read as a misalignment rather than a subtitle.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // No explicit colour: the island's own primary (white) is the legible one.
            Text(botName)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HermeyTurnStatusLine(state: state, botName: botName, isStale: isStale, tone: .island)
                .layoutPriority(1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The state in words: what the bot is doing, from the state the app last sent.
///
/// This used to be a literal — `"Working on your message"` while running, `"Replied"` when done —
/// which is why the card could describe a turn it knew nothing about and still have nothing to say
/// about *this* one. `state.step` is the line the coordinator fills from the model, and it is never
/// empty (`ContentState.stepLine` ends at a neutral word), so the sentence now varies with the turn
/// **and exists from the first frame of it**.
///
/// The literal survives only as the second floor, for a card requested by a build that predates the
/// field: a redraw of that activity decodes a missing `step`, and this is what it draws instead of a
/// blank line. Staleness is not an error: it means the app has not been able to update the card (it
/// was killed, or the turn is taking longer than the app promised), so the sentence steps back to
/// what is still true instead of claiming work that may have stopped.
private struct HermeyTurnStatusLine: View {
    let state: HermeyTurnAttributes.ContentState
    let botName: String
    let isStale: Bool
    var tone: HermeyTurnTone = .card

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(isStale ? tone.secondary : HermeyTurnAccent.amber)
            Text(line)
                .font(.caption2)
                .foregroundStyle(tone.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                // The line the card exists for: it keeps its height even when the row is tight, so
                // a running turn can never render as a panel with no words on it.
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        if state.phase == .done { return "checkmark.circle.fill" }
        return isStale ? "clock" : "circle.dotted"
    }

    private var line: String {
        if isStale { return "Still waiting on \(botName)" }
        let step = state.step
        guard step.isEmpty else { return step }
        // Only an activity from a build with no `step` reaches this: the state normalises to the
        // neutral word at construction and at decode.
        return state.phase == .done ? "Done" : "Working on your message"
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

/// The Lock Screen row: mark, brand, bot, state, and the reply's first line.
///
/// It is the same content as the expanded island, laid out a line taller because the Lock Screen
/// gives it a full card's width. `Hermey` is spelled out here — the card's job is to be identifiable
/// at a glance on a screen with several notifications on it.
///
/// **The step line is drawn for every phase, unconditionally.** It is the sentence that was missing
/// while a turn ran: the only text the card used to add at the end was the reply snippet, so a
/// working card was the name row and a line the layout could squeeze out. Nothing in this body
/// branches on `phase`, and the text column carries `.layoutPriority(1)` so the trailing number can
/// never take the width the words need.
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
                        .foregroundStyle(HermeyTurnTone.card.secondary)
                    Text(botName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .foregroundStyle(HermeyTurnTone.card.primary)
                }
                HermeyTurnStatusLine(state: state, botName: botName, isStale: isStale, tone: .card)
                HermeyTurnSnippet(state: state, tone: .card)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            HermeyTurnElapsedLabel(state: state, tone: .card)
        }
        .padding(.vertical, HermeyTurnGlass.cardVertical)
        .padding(.horizontal, HermeyTurnGlass.cardHorizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLine)
    }

    /// The snippet is read after the sentence rather than as a separate element: VoiceOver announces
    /// the card as one thing, and the words of the reply are the reason the owner raised his phone.
    /// The step is read too — "which bot" and "doing what" is the whole content of a running turn.
    private var accessibilityLine: String {
        let snippet = state.replySnippet
        let said = snippet.isEmpty ? "" : " \(snippet)"
        if isStale { return "Hermey. Still waiting on \(botName)." }
        switch state.phase {
        case .done: return "Hermey. \(botName): \(state.step).\(said)"
        case .working: return "Hermey. \(botName) is \(state.step)."
        }
    }
}
#endif
