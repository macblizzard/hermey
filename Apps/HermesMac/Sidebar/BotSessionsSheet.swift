import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// **All sessions…** — every conversation the host holds for one bot, newest first, with the one
/// on screen marked.
///
/// A bot's endless conversation is what the app opens; it is not the only session the host keeps.
/// Anything Hermes started on its own — a routine's run, a DM, a `hermes -p <bot> chat` from a
/// terminal — lives beside it, and until now the Mac had no door to any of them. Picking a row
/// resumes that session in the pane behind this sheet.
///
/// It reads `AppModel.sessions`, which is scoped to the *selected* bot, so the caller selects the
/// bot before presenting: a sheet that quietly listed another bot's history under this bot's name
/// is the one bug worth designing out.
struct BotSessionsSheet: View {
    @ObservedObject var model: AppModel
    let bot: Bot
    /// The chosen session: the caller resumes it and dismisses.
    var onOpen: (SessionSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hoveredID: String?

    private var rows: [SessionSummary] { model.sessions }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.sessionsLoading && rows.isEmpty {
                loading
            } else if rows.isEmpty {
                empty
            } else {
                list
            }
        }
        .padding(16)
        .frame(width: 560, height: 470)
        .background(Tokens.canvas)
        // Re-read on every open: a session started on the phone while this Mac was asleep is not
        // in the list this host sent an hour ago.
        .task(id: bot.id) { await model.loadSessions() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                SectionCaption("SESSIONS")
                Text(bot.displayName)
                    .font(TypeScale.font(TypeScale.lg, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            OpenBotIconButton("arrow.clockwise", label: "Refresh", size: .small,
                              isBusy: model.sessionsLoading) {
                Task { await model.loadSessions() }
            }
            .help("Ask the host for this bot's sessions again")

            OpenBotIconButton("xmark", label: "Close", size: .small) { dismiss() }
                .help("Close")
        }
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(rows) { session in
                    row(session)
                }
            }
            .padding(.vertical, 4)
        }
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                .fill(Tokens.sidebar)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                .strokeBorder(Tokens.border, lineWidth: 1)
        )
    }

    private func row(_ session: SessionSummary) -> some View {
        let isCurrent = model.selectedSessionID == session.id
        let isHovered = hoveredID == session.id

        return Button {
            onOpen(session)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.displayTitle)
                            .font(TypeScale.font(TypeScale.sessionTitle,
                                                 weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(Tokens.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if session.running {
                            // A word, not a moving bar: a list of sessions that animates in five
                            // rows is a list nobody can read (see the roster's own faces).
                            Text("RUNNING")
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(Tokens.success)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(Tokens.success.opacity(0.14))
                                )
                        }

                        if isCurrent {
                            Text("OPEN")
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(Tokens.accentText)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(Tokens.accent.opacity(0.16))
                                )
                        }

                        Spacer(minLength: 6)

                        if let at = session.updatedAt {
                            Text(RelativeTime.stamp(at))
                                .font(TypeScale.font(Tokens.rosterMeta))
                                .foregroundStyle(Tokens.textDim)
                                .monospacedDigit()
                                .lineLimit(1)
                                .layoutPriority(1)
                                .accessibilityLabel("updated \(RelativeTime.detailed(at))")
                        }
                    }

                    if let preview = session.preview, !preview.isEmpty {
                        Text(preview)
                            .font(TypeScale.font(Tokens.rosterMeta))
                            .foregroundStyle(Tokens.textMuted)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                    .fill(isCurrent ? Tokens.controlActive
                          : (isHovered ? Tokens.controlHover : .clear))
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { inside in
            if inside { hoveredID = session.id }
            else if hoveredID == session.id { hoveredID = nil }
        }
        .help(session.preview ?? session.displayTitle)
    }

    private var loading: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                SpinningRing(color: Tokens.textDim, size: 12, lineWidth: 1.4)
                Text("Reading this bot's sessions…")
                    .font(TypeScale.font(Tokens.textSM))
                    .foregroundStyle(Tokens.textMuted)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No sessions on this host for \(bot.displayName).")
                .font(TypeScale.font(Tokens.textSM, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)
            Text("The conversation on screen is the bot's own chat; if the host does not list it either, the connection has not answered a session list yet.")
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
private struct BotSessionsSheetPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        BotSessionsSheet(model: store.model,
                         bot: store.model.orderedBots.first
                             ?? Bot(id: "assistant", displayName: "Assistant"),
                         onOpen: { _ in })
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

#Preview("All sessions") {
    BotSessionsSheetPreview()
}
#endif
