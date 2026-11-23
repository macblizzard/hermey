import Foundation
import SwiftUI

/// Draws one native agent card — all three `card.v1` kinds.
///
/// * **approval** — the title, the body and the buttons. No status chip: the buttons *are* the
///   status, and the spec says not to repeat it.
/// * **task** — the same card with a status chip above the title (`running` with a spinner, and
///   `done`/`error` in the card's own colours), so a job that takes minutes says what it is doing.
/// * **draft-email** — a real draft: the subject as the heading (its title when there is no
///   subject), `To`/`Cc` rows, a scrollable preview of `bodyText`, then the buttons.
///
/// The body blocks are shared by all three (`text` paragraphs, `kv` rows, `fields` items), and so
/// is the resolved note: once the file carries `resolved`, every button locks and the card says
/// which action was taken.
///
/// All styling arrives through `CardTheme`; nothing here reads a colour from the design system,
/// which is what lets the target depend on `HermesKit` alone.
public struct CardView: View {
    private let model: CardModel
    private let theme: CardTheme
    private let onAction: ((Card.Action) -> Void)?

    /// - Parameters:
    ///   - model: the decoded document, or `.unavailable` after a 404 / broken file.
    ///   - theme: the app's palette. Defaults to the house light palette.
    ///   - onAction: called with the tapped action; the caller sends `action.send` as a user turn.
    public init(model: CardModel,
                theme: CardTheme = .hermey,
                onAction: ((Card.Action) -> Void)? = nil) {
        self.model = model
        self.theme = theme
        self.onAction = onAction
    }

    public var body: some View {
        Group {
            switch model {
            case .unavailable(let message):
                unavailable(message)
            case .available(let card):
                switch card.kind {
                case .approval:
                    // The spec draws an approval without a status chip: its buttons *are* the
                    // status, and repeating it above them says nothing new.
                    surface(card, header: { EmptyView() }, extra: { EmptyView() })
                case .task:
                    surface(card, header: { statusChip(card) }, extra: { EmptyView() })
                case .draftEmail:
                    surface(card, header: { draftEyebrow() }, extra: { draftDetails(card) })
                }
            }
        }
    }

    // MARK: - Unavailable

    private func unavailable(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.mutedInk)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(theme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }

    // MARK: - The shared card

    /// The card every kind is built from: an optional header above the heading, that heading, the
    /// body (or the one-line lead that stands in for it), any kind-specific details, the resolved
    /// note, then at most three buttons.
    private func surface<Header: View, Extra: View>(
        _ card: Card,
        @ViewBuilder header: () -> Header,
        @ViewBuilder extra: () -> Extra
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header()

            Text(card.heading)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            extra()

            if let lead = card.leadText {
                // One short line reads as the question under the title, not as a paragraph.
                Text(lead)
                    .font(.system(size: 13.5))
                    .foregroundStyle(theme.ink)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // An empty body draws nothing at all: no gap, no placeholder.
                ForEach(card.body.indices, id: \.self) { index in
                    bodyBlock(card.body[index])
                }
            }

            if let label = card.resolvedLabel {
                resolvedNote(label)
            }

            if !card.actions.isEmpty {
                actionRow(card)
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        // One element with children: VoiceOver reads a card as a card with a title, its facts and
        // its answers, not as seven unrelated labels.
        .accessibilityElement(children: .contain)
    }

    // MARK: - Status chip

    /// The chip a `task` card carries. Its word is the bot's `status.label` when the file wrote
    /// one, else the state's own, and a `running` task spins so "still going" needs no words.
    private func statusChip(_ card: Card) -> some View {
        let state = card.status.state

        return HStack(spacing: 5) {
            if state == .running {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 11, height: 11)
            } else if let glyph = statusGlyph(state) {
                Image(systemName: glyph)
                    .font(.system(size: 9.5, weight: .bold))
            }

            Text(card.status.chipText)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(statusInk(state))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(statusFill(state))
        )
        .overlay(
            Capsule().strokeBorder(theme.border, lineWidth: 1)
        )
        // The state in words, whatever the chip draws.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(card.status.chipText)")
    }

    private func statusGlyph(_ state: Card.StatusState) -> String? {
        switch state {
        case .pending, .awaitingApproval: return "clock"
        case .done: return "checkmark"
        case .error: return "exclamationmark"
        case .running: return nil
        }
    }

    private func statusFill(_ state: Card.StatusState) -> Color {
        switch state {
        case .done: return theme.accent.opacity(0.14)
        case .error: return theme.danger.opacity(0.12)
        case .pending, .running, .awaitingApproval: return theme.canvas
        }
    }

    private func statusInk(_ state: Card.StatusState) -> Color {
        switch state {
        case .done: return theme.ink
        case .error: return theme.danger
        case .pending, .running, .awaitingApproval: return theme.mutedInk
        }
    }

    // MARK: - Draft email

    private func draftEyebrow() -> some View {
        HStack(spacing: 5) {
            Image(systemName: "envelope")
                .font(.system(size: 9.5, weight: .semibold))

            Text("Draft email")
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(theme.mutedInk)
        .accessibilityHidden(true)
    }

    /// The draft itself: who it goes to, who is copied, and the message in a scrolling preview.
    /// A row that the file left out is not drawn; a draft with no `email` block is just a heading.
    @ViewBuilder
    private func draftDetails(_ card: Card) -> some View {
        if let email = card.email {
            VStack(alignment: .leading, spacing: 8) {
                if let to = email.to, !to.isEmpty {
                    row("To", to)
                }
                if let cc = email.cc, !cc.isEmpty {
                    row("Cc", cc)
                }
                if let text = email.bodyText {
                    emailBody(text)
                }
            }
        }
    }

    private func emailBody(_ text: String) -> some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(theme.ink)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        // A draft's body can be a page long (32 KB of card is allowed); it scrolls inside the
        // card rather than pushing the buttons — and the reply under them — off the screen.
        .frame(maxHeight: previewHeight(for: text))
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                .fill(theme.canvas)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .accessibilityLabel("Email body")
        .accessibilityValue(text)
    }

    /// How tall the preview is allowed to be: enough for the text, never more than most of a
    /// screen. `ScrollView` is greedy, so the height has to be decided here — an unmeasured
    /// `maxHeight` alone would leave a short draft in a tall empty box.
    private func previewHeight(for text: String) -> CGFloat {
        let hardLines = text.components(separatedBy: "\n").count
        // ~46 characters to a line at 13 pt inside this width, and every wrapped line is 17 pt.
        let wrapped = max(hardLines, text.count / 46 + 1)
        return min(196, max(30, CGFloat(wrapped) * 17 + 4))
    }

    // MARK: - Resolved

    /// Which button the owner pressed, under the body and above the (now locked) buttons.
    private func resolvedNote(_ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))

            Text("Resolved: \(label)")
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(theme.mutedInk)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Resolved: \(label)")
    }

    // MARK: - Body blocks

    @ViewBuilder
    private func bodyBlock(_ block: Card.BodyBlock) -> some View {
        switch block {
        case .text(let text):
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(theme.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .kv(let rows):
            rowsView(rows)
        case .fields(let rows):
            rowsView(rows)
        }
    }

    private func rowsView(_ rows: [Card.Row]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows.indices, id: \.self) { index in
                row(rows[index].label, rows[index].value)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(theme.mutedInk)
                .frame(minWidth: 72, alignment: .leading)

            Text(value)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private func actionRow(_ card: Card) -> some View {
        HStack(spacing: 8) {
            ForEach(card.actions.indices, id: \.self) { index in
                actionButton(card, card.actions[index])
            }
        }
    }

    private func actionButton(_ card: Card, _ action: Card.Action) -> some View {
        let state = card.state(of: action)

        return Button {
            onAction?(action)
        } label: {
            HStack(spacing: 5) {
                if state == .chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }

                Text(action.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(labelColor(action))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                    .fill(fill(action))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                    .strokeBorder(borderColor(action), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        // Resolved means answered: the chosen button shows the tick, and nothing is tappable —
        // including the choice itself, so a second tap cannot send a second turn.
        .disabled(state != .available)
        .opacity(state == .locked ? 0.45 : 1)
        // The label is what the owner reads and what VoiceOver should say, never `send`.
        .accessibilityLabel(action.label)
    }

    private func fill(_ action: Card.Action) -> Color {
        switch action.style {
        case .some(.primary): return theme.accent
        case .some(.danger): return theme.danger.opacity(0.12)
        case .none: return theme.canvas
        }
    }

    private func labelColor(_ action: Card.Action) -> Color {
        switch action.style {
        case .some(.primary): return theme.accentInk
        case .some(.danger): return theme.danger
        case .none: return theme.ink
        }
    }

    private func borderColor(_ action: Card.Action) -> Color {
        switch action.style {
        case .some(.primary): return theme.accent
        case .some(.danger): return theme.danger.opacity(0.35)
        case .none: return theme.border
        }
    }
}
