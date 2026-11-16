import SwiftUI
import HermesKit
import HermesAppKit
import HermeyUI

/// **All sessions…** — every conversation the host holds for one bot, newest first, with the one
/// on screen marked.
///
/// The phone's bot list draws one row per bot, and tapping that row opens the bot's endless
/// `Bot Chat`; it is not the only session the host keeps. Anything Hermes started on its own — a
/// routine's run, a DM from another bot, a `hermes -p <bot> chat` from a terminal — lives beside it,
/// and until now iOS had no door to any of them. This is the Mac's sheet (`BotSessionsSheet` in the
/// Mac app) brought to the phone: the same rows, the same two chips, the same refresh.
///
/// It reads `AppModel.sessions`, which is scoped to the *selected* bot, so the caller selects the
/// bot before presenting — a sheet that quietly listed another bot's history under this bot's name
/// is the one bug worth designing out. The scope is checked again here (`isScopedToBot`), so even a
/// caller that presents too early draws a spinner rather than the wrong bot's conversations.
struct BotSessionsSheet: View {
    @ObservedObject var model: AppModel
    let bot: Bot
    /// The chosen session: the caller opens it, and this sheet closes.
    var onOpen: (SessionSummary) -> Void

    @Environment(\.dismiss) private var dismiss

    /// The model's list belongs to the bot it was fetched for. Drawing it under any other name is
    /// the mix this surface exists to prevent, so nothing is drawn until the two agree.
    private var isScopedToBot: Bool { model.selectedBotID == bot.id }

    private var rows: [SessionSummary] { isScopedToBot ? model.sessions : [] }

    private var isLoading: Bool { !isScopedToBot || (model.sessionsLoading && rows.isEmpty) }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    loading
                } else if rows.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .navigationTitle(bot.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { refreshButton }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Re-read on every open: a session started on the Mac while this phone was in a pocket is
        // not in the list this host sent an hour ago.
        .task(id: bot.id) { await model.loadSessions() }
        .accessibilityIdentifier("botSessionsSheet")
    }

    // MARK: Rows

    private var list: some View {
        List {
            Section {
                ForEach(rows) { session in
                    row(session)
                }
            } footer: {
                Text("Newest first. OPEN is the conversation this bot opens with; anything else was started on the host — a routine's run, another bot, or a terminal.")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textDim)
            }
        }
        .listStyle(.insetGrouped)
        // A pull is a request for what the host holds *now*, not for the list it answered before.
        .refreshable { await model.loadSessions() }
    }

    private func row(_ session: SessionSummary) -> some View {
        let isCurrent = model.selectedSessionID == session.id
        // `session.running` is the host's answer at the moment the list was read; a turn that
        // started afterwards is not in it, and the model's live set is. Either one means RUNNING.
        let isRunning = session.running || model.runningSessions.contains(session.id)

        return Button {
            Haptics.selection()
            onOpen(session)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.displayTitle)
                        .font(TypeScale.font(TypeScale.md, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(Tokens.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if isRunning {
                        // A word, not a moving bar: a list of sessions that animates in five rows
                        // is a list nobody can read. Same chip as the Mac's, at the same size.
                        chip("RUNNING", color: Tokens.success, fill: Tokens.success.opacity(0.14))
                    }

                    if isCurrent {
                        chip("OPEN", color: Tokens.accentText, fill: Tokens.accent.opacity(0.16))
                    }

                    Spacer(minLength: 6)

                    if let at = session.updatedAt {
                        Text(RelativeTime.stamp(at))
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textDim)
                            .monospacedDigit()
                            .lineLimit(1)
                            .layoutPriority(1)
                            .accessibilityLabel("updated \(RelativeTime.detailed(at))")
                    }
                }

                if let preview = session.preview, !preview.isEmpty {
                    Text(preview)
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.textMuted)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The row on screen is filled as well as chipped: the chip says which one, the fill makes
        // it findable in a list the eye is already skimming. Every other row keeps the grouped
        // card, so the fill is the only row that looks different.
        .listRowBackground(isCurrent ? Tokens.controlActive : Tokens.grouped)
        .accessibilityLabel(accessibilityLabel(for: session, current: isCurrent, running: isRunning))
    }

    private func chip(_ text: String, color: Color, fill: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(fill)
            )
            .fixedSize()
    }

    // MARK: Chrome

    private var refreshButton: some View {
        Button {
            Task { await model.loadSessions() }
        } label: {
            if model.sessionsLoading {
                SpinningRing(color: Tokens.textDim, size: 12, lineWidth: 1.4)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(model.sessionsLoading)
        .accessibilityLabel("Refresh sessions")
    }

    private var loading: some View {
        VStack(spacing: 8) {
            SpinningRing(color: Tokens.textDim, size: 12, lineWidth: 1.4)
            Text("Reading this bot's sessions…")
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(Tokens.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No sessions", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("The host lists no conversations for \(bot.displayName). The chat this bot opens with counts as one — if it is missing too, the connection has not answered a session list yet.")
        } actions: {
            Button("Try again") {
                Task { await model.loadSessions() }
            }
        }
    }

    /// One sentence for VoiceOver: which conversation, whether it is moving, whether it is the one
    /// on screen, and when it last spoke.
    private func accessibilityLabel(for session: SessionSummary,
                                    current: Bool,
                                    running: Bool) -> String {
        var parts = [session.displayTitle]
        if running { parts.append("running") }
        if current { parts.append("open") }
        if let at = session.updatedAt { parts.append("updated \(RelativeTime.detailed(at))") }
        return parts.joined(separator: ", ")
    }
}
