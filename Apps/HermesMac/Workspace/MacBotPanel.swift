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
            Hairline(color: Tokens.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // What the bot works with, in the order the phone lists it.
                    row("Computer", icon: "display",
                        detail: store.isComputerPanelPresented ? "open" : nil,
                        detailTone: store.isComputerPanelPresented ? Tokens.accent : Tokens.textDim) {
                        store.toggleComputerPanel()
                    }

                    section
                    row("Workspace", icon: "folder") { if let bot { store.openWorkspace(bot) } }
                    row("Skills", icon: "book.closed") { if let bot { store.openSkills(bot) } }
                    row("MCP servers", icon: "puzzlepiece.extension") { if let bot { store.openMCP(bot) } }

                    section
                    row("Search conversation", icon: "magnifyingglass", detail: "⌘F") {
                        store.openFindInChat()
                    }
                    row("Bot settings", icon: "gearshape") {
                        if let bot { store.openBotSettings(bot) }
                    }

                    section
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
                    row("Mark all as read", icon: "checkmark.circle",
                        isDisabled: !model.hasAnyUnread) {
                        model.markAllRead()
                    }

                    section
                    row("Reset conversation", icon: "arrow.counterclockwise", tone: Tokens.danger,
                        isDisabled: !model.canActOnConversation) {
                        store.isResetConfirmationPresented = true
                    }

                    section
                    row("Command palette", icon: "command", detail: "⌘K") { store.openPalette() }
                    row("Settings", icon: "slider.horizontal.3", detail: "⌘,") { openSettings() }

                    section
                    connectionRow
                }
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

    /// Who this panel is about, at the size a panel can afford: the portrait the roster shows, the
    /// name, and the line the header has no room for.
    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            if let bot {
                BotIconPortrait(store.botFaces[bot.id] ?? BotFace.default(for: bot.id),
                                size: 38,
                                isWorking: model.isStreaming)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(bot?.displayName ?? model.hostName)
                    .font(TypeScale.font(TypeScale.sessionTitle, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(TypeScale.font(TypeScale.micro))
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            OpenBotIconButton("xmark", label: "Close the bot panel", size: .small) { close() }
                .help("Close (esc)")
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    /// The description the host gives the bot, or — when it has none — the one fact the header
    /// used to carry: how much conversation there is and how much room it has left.
    private var subtitle: String {
        if let described = bot?.description, !described.isEmpty { return described }
        if !store.isPaired { return "no host paired" }
        if !model.connection.isLive { return "not connected" }
        var parts: [String] = []
        if !model.transcript.isEmpty {
            parts.append(model.transcript.count == 1 ? "1 entry" : "\(model.transcript.count) entries")
        }
        if let used = model.contextUsed {
            if let max = model.contextMax, max > 0 {
                parts.append("\(TokenCount.short(used)) / \(TokenCount.short(max)) context")
            } else {
                parts.append("\(TokenCount.short(used)) context")
            }
        }
        return parts.isEmpty ? "no conversation open" : parts.joined(separator: " · ")
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
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered == title && !isDisabled ? Tokens.surface.opacity(0.9) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .padding(.horizontal, 8)
        .onHover { inside in
            if inside { hovered = title }
            else if hovered == title { hovered = nil }
        }
    }

    /// The wire, at the bottom where a status belongs: what it is, and the one verb that changes
    /// it. Pairing lives here because a panel about this bot is where you notice it is not talking.
    private var connectionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.connection.isLive ? Tokens.success : Tokens.textDim)
                    .frame(width: 6, height: 6)
                Text(model.connection.isLive ? "connected to \(model.hostName)"
                                             : (store.isPaired ? "not connected" : "no host paired"))
                    .font(TypeScale.font(TypeScale.micro))
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)

            HStack(spacing: 8) {
                if store.isPaired {
                    if model.connection.isLive {
                        panelButton("Disconnect", tone: Tokens.textMuted) {
                            Task { await store.disconnect() }
                        }
                    } else {
                        panelButton("Connect", tone: Tokens.accentText) {
                            Task { await store.connect() }
                        }
                    }
                }
                panelButton("Pair host…", tone: Tokens.textMuted) {
                    store.isPairSheetPresented = true
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
        }
        .padding(.top, 4)
    }

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
