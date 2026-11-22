import SwiftUI

/// Draws one native agent card.
///
/// P1 draws the **approval** layout only: a title, the body blocks (text paragraphs and
/// label/value rows), and at most three action buttons. `task` and `draft-email` decode into the
/// same model but are drawn in P3/P4; until then this view draws nothing for them, which leaves
/// the reply's prose as the whole message — the honest result, not a half-card.
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
                if card.kind == .approval {
                    approval(card)
                } else {
                    // P1 scope: task cards poll on their own clock and draft-email has its own
                    // layout. Drawing neither is better than drawing an approval-shaped lie.
                    EmptyView()
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

    // MARK: - Approval

    private func approval(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(card.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(card.body.indices, id: \.self) { index in
                bodyBlock(card.body[index])
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
        // One element with children: VoiceOver reads an approval as a card with a title, its
        // facts and its answers, not as seven unrelated labels.
        .accessibilityElement(children: .contain)
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
                let row = rows[index]
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.label)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.mutedInk)
                        .frame(minWidth: 72, alignment: .leading)

                    Text(row.value)
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
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
