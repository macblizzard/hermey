import Foundation
import SwiftUI

/// Draws one native agent card — all three `card.v1` kinds.
///
/// * **approval** — the title, the body and the buttons. No status chip: the buttons *are* the
///   status, and the spec says not to repeat it.
/// * **task** — the same card with a status chip above the title (`running` with a spinner, and
///   `done`/`error` in the card's own colours), so a job that takes minutes says what it is doing.
/// * **draft-email** — a real, *editable* draft: `To`/`Cc`/`Subject` are text fields, `bodyText` is
///   a multi-line editor, and the card ends in exactly two buttons, Send and Discard. A bot drafts
///   so the owner can change a word before it goes; asking him to tap "Edit" first would only be a
///   second mode over the same four values.
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

    /// What the owner has typed, and nothing else. `nil` until the first keystroke, at which point
    /// the field's value comes from the card the host wrote instead — so a card nobody edits holds
    /// no copy of its own document, and a reload can never show a stale edit over new text.
    ///
    /// There is no persistence and no write back: the bot owns the file, the client owns only what
    /// is being typed right now.
    @State private var draft: DraftEditor?

    /// Discard is local. It hides the draft's message and buttons; it posts no turn, so the agent
    /// is never told to act on an email the owner only meant to put down.
    @State private var discarded = false

    /// - Parameters:
    ///   - model: the decoded document, or `.unavailable` after a 404 / broken file.
    ///   - theme: the app's palette. Defaults to the house light palette.
    ///   - onAction: called with the tapped action; the caller sends `action.send` as a user turn.
    ///     A live draft's Send is handed over as a `Card.Action` whose `send` is the composed
    ///     block (`DraftEditor.composedSend(lead:)`), so it rides the same path every other card's
    ///     buttons already use. Discard never calls it.
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
                    surface(card, header: { EmptyView() }, extra: { EmptyView() }, controls: { actionRow(card) })
                case .task:
                    surface(card, header: { statusChip(card) }, extra: { EmptyView() }, controls: { actionRow(card) })
                case .draftEmail:
                    // A draft with no `email` block has nothing to edit and draws exactly as it
                    // did before. A resolved one is answered: read-only facts, its note, no fields
                    // and no buttons — a locked card is a receipt, not a form.
                    if card.email != nil, !card.isResolved {
                        draftEditorSurface(card)
                    } else if card.isResolved {
                        surface(card, header: { draftEyebrow() }, extra: { draftDetails(card) }, controls: { EmptyView() })
                    } else {
                        surface(card, header: { draftEyebrow() }, extra: { draftDetails(card) }, controls: { actionRow(card) })
                    }
                }
            }
        }
        .onChange(of: draftSeed) { _, _ in
            // A different document is a different draft: the host rewrote the email, or a second
            // card took this view's place. The typing belonged to the old draft, so it goes.
            // `draftSeed` is derived from the document's own email, so an ordinary re-render (or a
            // status update on the same text) leaves what the owner is typing alone.
            self.draft = nil
            self.discarded = false
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
    /// note, then whatever controls the kind supplies — at most three buttons, or a draft's
    /// Send/Discard pair.
    private func surface<Header: View, Extra: View, Controls: View>(
        _ card: Card,
        showsHeading: Bool = true,
        showsBody: Bool = true,
        @ViewBuilder header: () -> Header,
        @ViewBuilder extra: () -> Extra,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header()

            if showsHeading {
                Text(card.heading)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            extra()

            if showsBody {
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
            }

            if let label = card.resolvedLabel {
                resolvedNote(label)
            }

            controls()
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

    /// The read-only draft: who it goes to, who is copied, and the message in a scrolling preview.
    /// A row that the file left out is not drawn; a draft with no `email` block is just a heading.
    ///
    /// This is the resolved card's layout and the layout of a draft there is nothing to edit in.
    /// A live draft draws `draftFields` instead.
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

    // MARK: - The live draft

    /// A draft is a form, not a poster: four fields, then Send and Discard.
    private func draftEditorSurface(_ card: Card) -> some View {
        surface(card,
                showsHeading: false,
                showsBody: false,
                header: { draftEyebrow() },
                extra: { draftFields(card) },
                controls: { draftControls(card) })
            // A discarded draft stays legible — it is what the owner put down — but dimmed, so
            // nothing about it looks answerable.
            .opacity(discarded ? 0.55 : 1)
    }

    private func draftFields(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            draftField("To", binding(\.to, in: card))
            draftField("Cc", binding(\.cc, in: card))
            draftField("Subject", binding(\.subject, in: card))
            draftBody(binding(\.body, in: card))
        }
        .disabled(discarded)
    }

    private func draftField(_ label: String, _ text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(theme.mutedInk)
                .frame(minWidth: 72, alignment: .leading)

            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                        .fill(theme.canvas)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
                // The visible label above is the field's name; VoiceOver says it too.
                .accessibilityLabel(label)
        }
        .accessibilityElement(children: .contain)
    }

    private func draftBody(_ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Message")
                .font(.system(size: 12))
                .foregroundStyle(theme.mutedInk)

            TextEditor(text: text)
                .font(.system(size: 13))
                .foregroundStyle(theme.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110, maxHeight: 196)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                        .fill(theme.canvas)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
                .accessibilityLabel("Email body")
        }
    }

    /// Send and Discard, whatever the file's `actions` say: a draft's two answers do not change
    /// from bot to bot, and a third — "Edit" — is the fields the owner is already looking at.
    @ViewBuilder
    private func draftControls(_ card: Card) -> some View {
        if discarded {
            HStack(spacing: 5) {
                Image(systemName: "tray")
                    .font(.system(size: 10, weight: .semibold))

                Text("Discarded")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(theme.mutedInk)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Discarded")
        } else {
            HStack(spacing: 8) {
                draftButton("Send", style: .primary) {
                    self.send(card)
                }
                draftButton("Discard", style: .danger) {
                    // Local only: no turn, no resolution, nothing for the agent to act on.
                    self.discarded = true
                }
            }
            .padding(.top, 2)
        }
    }

    private func draftButton(_ label: String, style: Card.ActionStyle?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(labelColor(style))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                        .fill(fill(style))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                        .strokeBorder(borderColor(style), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The turn a typed draft sends: the card's own send token first (so the agent still sees the
    /// intent), then the composed block with whatever is in the fields right now.
    private func send(_ card: Card) {
        guard let typed = editor(for: card) else { return }
        let action = card.draftSendAction
        onAction?(Card.Action(label: "Send",
                              send: typed.composedSend(lead: action?.send),
                              style: .primary))
    }

    /// What the owner is typing, or — before the first keystroke — the card exactly as written.
    private func editor(for card: Card) -> DraftEditor? {
        draft ?? DraftEditor.editor(for: card)
    }

    /// A field's value: the typed draft wins, and a keystroke is what turns "the card" into "the
    /// card plus my edits". A re-render only ever re-reads this — it never writes the card back
    /// over the typing.
    private func binding(_ keyPath: WritableKeyPath<DraftEditor, String>, in card: Card) -> Binding<String> {
        Binding(
            get: { self.editor(for: card)?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard var editing = self.editor(for: card) else { return }
                editing[keyPath: keyPath] = newValue
                self.draft = editing
            }
        )
    }

    /// The identity of the document being edited, from the only thing this view is given: its
    /// text. A re-render or a status change leaves it alone; a rewritten draft changes it.
    private var draftSeed: String {
        guard case .available(let card) = model, card.kind == .draftEmail, let email = card.email else {
            return ""
        }
        return [email.to ?? "", email.cc ?? "", email.subject ?? "", email.bodyText ?? ""]
            .joined(separator: "\u{1E}")
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

    @ViewBuilder
    private func actionRow(_ card: Card) -> some View {
        if !card.actions.isEmpty {
            HStack(spacing: 8) {
                ForEach(card.actions.indices, id: \.self) { index in
                    actionButton(card, card.actions[index])
                }
            }
            .padding(.top, 2)
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
            .foregroundStyle(labelColor(action.style))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                    .fill(fill(action.style))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radiusControl, style: .continuous)
                    .strokeBorder(borderColor(action.style), lineWidth: 1)
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

    private func fill(_ style: Card.ActionStyle?) -> Color {
        switch style {
        case .some(.primary): return theme.accent
        case .some(.danger): return theme.danger.opacity(0.12)
        case .none: return theme.canvas
        }
    }

    private func labelColor(_ style: Card.ActionStyle?) -> Color {
        switch style {
        case .some(.primary): return theme.accentInk
        case .some(.danger): return theme.danger
        case .none: return theme.ink
        }
    }

    private func borderColor(_ style: Card.ActionStyle?) -> Color {
        switch style {
        case .some(.primary): return theme.accent
        case .some(.danger): return theme.danger.opacity(0.35)
        case .none: return theme.border
        }
    }
}
