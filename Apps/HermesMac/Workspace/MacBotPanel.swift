import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The bot's own panel, on the right edge: everything that acts on *this* conversation, one click
/// from the name at the centre of the header.
///
/// Rakazo puts its verbs in a panel beside the chat rather than in a menu bar across the top. The
/// reason is the same one that made the phone's drawer work: a dropdown is a list you have to aim
/// at and re-open for every verb, while a panel can stay open beside the thing it acts on — you
/// compact a long conversation and watch the transcript rewrite itself without the panel closing
/// over it.
///
/// It is a *panel*, not a sheet: nothing here is modal, and the transcript keeps scrolling behind
/// it. Escape and the ✕ both put it away, and so does the same ⋯ that opened it.
struct MacBotPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore

    /// ⌘, — the real Settings scene, the same door the menu bar opens.
    @Environment(\.openSettings) private var openSettings

    /// One row at a time wears the hover fill, keyed by its title.
    @State private var hovered: String?

    private var bot: Bot? { model.selectedBot }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 10) {
                    // The phone's grouping, in the phone's order: what the bot reaches for, what it
                    // can do without being asked, what it is, and the two verbs that end something.
                    panel {
                        row("Computer", icon: "display",
                            detail: store.isComputerPanelPresented ? "open" : nil,
                            detailTone: store.isComputerPanelPresented ? Tokens.accent : Tokens.textDim) {
                            store.toggleComputerPanel()
                        }
                        rowDivider
                        // "Library", not "Workspace": the row opens this bot's files, and the word
                        // the desktop uses for the agent's own folder is a developer's word for it.
                        row("Library", icon: "folder") { if let bot { store.openWorkspace(bot) } }
                    }

                    panel {
                        // Which model answers, beside the other facts about how this bot behaves.
                        row("Model", icon: "cpu") { if let bot { store.openModel(bot) } }
                        rowDivider
                        row("Skills", icon: "book.closed") { if let bot { store.openSkills(bot) } }
                        rowDivider
                        row("MCP", icon: "puzzlepiece.extension") { if let bot { store.openMCP(bot) } }
                        rowDivider
                        row("Routines", icon: "clock.arrow.circlepath") {
                            if let bot { store.openRoutines(bot) }
                        }
                    }

                    panel {
                        // "Search conversations" — the scope, said out loud: it searches this bot's
                        // talk, not the host's files (that is Library) and not the app's settings.
                        row("Search conversations", icon: "magnifyingglass") {
                            store.openFindInChat()
                        }
                    }

                    panel {
                        // The verb keeps its row while it runs: a row that vanishes mid-compaction
                        // reads as "it never started", and the host takes 74–163 s on a real run.
                        row(model.isCompressing ? "Compacting…" : "Compact conversation",
                            icon: model.isCompressing ? "hourglass" : "rectangle.compress.vertical",
                            detail: model.isCompressing ? "working" : nil,
                            detailTone: Tokens.textDim,
                            isBusy: model.isCompressing,
                            isDisabled: !model.canActOnConversation || model.isCompressing) {
                            Task { await model.compressNow() }
                        }
                        rowDivider
                        row("Mark all as read", icon: "checkmark.circle",
                            isDisabled: !model.hasAnyUnread) {
                            model.markAllRead()
                        }
                    }

                    panel {
                        row("Reset chat", icon: "arrow.counterclockwise", tone: Tokens.danger,
                            isDisabled: !model.canActOnConversation) {
                            store.isResetConfirmationPresented = true
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 14)
            }
        }
        .frame(width: WindowLayout.botPanelWidth)
        .frame(maxHeight: .infinity)
        // The panel is a sheet of its own: one step off the chat's canvas, so the boundary is a
        // change of surface rather than a drawn line — the hairline on the leading edge is there
        // for the moment the two shades happen to match.
        .background(Tokens.sheet)
        .overlay(alignment: .leading) { Hairline(.vertical, color: Tokens.border) }
        // Escape puts it away. The panel is not modal, so it does not steal the keyboard; this
        // only fires when the pointer or the focus is already in it.
        .onExitCommand { close() }
        .background(
            // A hidden button is the only way to own Escape while the composer holds focus.
            Button("") { close() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.16)) { store.isBotPanelPresented = false }
    }

    // MARK: - Header

    /// One row, one control: the ✕.
    ///
    /// The panel used to open with the bot's portrait, its name and its description — the same
    /// three things the pill at the centre of the conversation already says, one column to the
    /// left. A panel that repeats the header it hangs off is a panel that costs 70 pt to say
    /// nothing new, and it pushed the verbs down out of reach.
    /// The phone's header: the bot's face, at a size that says which bot this panel is about, its
    /// name, and the one verb that is about the bot rather than its contents.
    ///
    /// The panel used to open with a lone ✕, on the argument that the pill already says the name.
    /// True, and still: a menu with no face in it looked like a settings column rather than like the
    /// page the phone opens from the same pill. The face is the animated one — it breathes and
    /// blinks wherever it is drawn (asked for 2026-11-14).
    private var header: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 8) {
                    if let bot {
                        BotIconPortrait(store.botFaces[bot.id] ?? BotFace.default(for: bot.id),
                                        size: 56,
                                        isWorking: model.isStreaming,
                                        status: model.hasPendingRequests ? .needsYou
                                              : (model.isCompressing ? .compacting : nil))
                    } else {
                        Avatar("No bot", size: .small, presence: .idle)
                    }

                    Text(bot?.displayName ?? "No bot")
                        .font(TypeScale.font(Tokens.sessionTitle, weight: .semibold))
                        .foregroundStyle(Tokens.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    if let description = bot?.description?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !description.isEmpty {
                        Text(description)
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textMuted)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        if let bot { store.openBotSettings(bot) }
                    } label: {
                        Text("Edit")
                            .font(TypeScale.font(TypeScale.sm, weight: .medium))
                            .foregroundStyle(Tokens.textPrimary)
                            .padding(.horizontal, 18)
                            .frame(height: 30)
                            .background(Capsule().fill(Tokens.surface))
                            .overlay(Capsule().strokeBorder(Tokens.border, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(bot == nil)
                    .help("Bot settings")
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)

                OpenBotIconButton("xmark", label: "Close the bot panel", size: .small) { close() }
                    .help("Close (esc)")
            }
            .padding(.horizontal, 10)
        }
        .padding(.bottom, 10)
    }

    /// One group of verbs: the phone's card — its corner radius, its fill, a divider between rows
    /// that starts where the words do.
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Tokens.surface.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Tokens.border, lineWidth: 1)
            )
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Tokens.border)
            .frame(height: 1)
            .padding(.leading, 46)
    }

    // MARK: - Rows

    private var section: some View {
        Hairline(color: Tokens.border)
            .padding(.vertical, 6)
            .padding(.horizontal, 14)
    }

    /// One verb. The whole row is the target — a menu whose items are only as wide as their words
    /// is a menu you miss.
    @ViewBuilder
    private func row(_ title: String,
                     icon: String,
                     detail: String? = nil,
                     detailTone: Color = Tokens.textDim,
                     tone: Color = Tokens.textPrimary,
                     isBusy: Bool = false,
                     isDisabled: Bool = false,
                     run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isDisabled ? Tokens.textDim : tone)
                    .frame(width: 18, alignment: .center)

                Text(title)
                    .font(TypeScale.font(TypeScale.md))
                    .foregroundStyle(isDisabled ? Tokens.textDim : tone)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                } else if let detail {
                    Text(detail)
                        .font(TypeScale.font(TypeScale.micro))
                        .monospacedDigit()
                        .foregroundStyle(detailTone)
                        .lineLimit(1)
                } else {
                    // The phone's chevron: every row here opens something, so every row says so.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.textDim)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered == title && !isDisabled ? Tokens.surface.opacity(0.9) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { inside in
            if inside { hovered = title }
            else if hovered == title { hovered = nil }
        }
    }

    // The connection row is gone: the wire belongs to the window, not to a panel about one bot.
    // A bot that stops answering says so in its face and in the header's own notice, and the
    // verbs that change the wire live in the app's Settings scene, where pairing already is.

    private func panelButton(_ title: String, tone: Color, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .font(TypeScale.font(TypeScale.micro, weight: .medium))
                .foregroundStyle(tone)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Tokens.surface))
                .overlay(Capsule().strokeBorder(Tokens.border, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
