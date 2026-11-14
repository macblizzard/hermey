import SwiftUI
import HermesAppKit
import OpenBotUI

/// A bot's own page, sliding up from the bottom, opened by tapping the pill.
///
/// It used to be a panel that slid in from the trailing edge, which meant the chat stayed half
/// visible behind a strip of verbs. The page a phone actually wants is the bot's: its portrait and
/// name at the top with one way to *edit* it, then the verbs in groups you can read at a glance —
/// the shape the reference apps use, where the header answers "which bot" and the list answers
/// "what can I do to it".
///
/// Closed by the back button in the corner or by swiping down. A full-height page, not a card:
/// this belongs to the chat it came from and it covers it whole.
struct ConversationDrawer: View {
    let title: String
    let subtitle: String?
    let face: BotFace
    let isCompressing: Bool
    let hasAnyUnread: Bool
    let canSpeak: Bool
    let speakReplies: Bool

    let onComputer: () -> Void
    let onWorkspace: () -> Void
    let onSkills: () -> Void
    let onMCP: () -> Void
    let onSearch: () -> Void
    let onSettings: () -> Void
    let onCompact: () -> Void
    let onMarkAllRead: () -> Void
    let onSpeakChange: (Bool) -> Void
    let onReset: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar

            ScrollView {
                VStack(spacing: 20) {
                    header
                    verbs
                    footer
                }
                .padding(.horizontal, Geometry.chatGutter)
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tokens.canvas)
        .transition(.move(edge: .bottom))
        .accessibilityAddTraits(.isModal)
        .gesture(
            // Swipe down to put it away, with the same drift guard the row list needs: a horizontal
            // flick is not a dismissal.
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if value.translation.height > 80,
                       abs(value.translation.height) > abs(value.translation.width) {
                        onClose()
                    }
                }
        )
    }

    /// The one control that is always in the same place: back.
    private var topBar: some View {
        HStack {
            Button {
                Haptics.selection()
                onClose()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .frame(width: 44, height: 44)
                    .hermeyGlass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close the bot page")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Geometry.chatGutter)
        .padding(.top, 4)
    }

    /// The bot, at a size that says which page you are on, with the one verb that is about the bot
    /// itself rather than its contents.
    private var header: some View {
        VStack(spacing: 12) {
            BotIconPortrait(face, size: 72)

            Text(title)
                .font(TypeScale.font(TypeScale.sessionTitle, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Button {
                Haptics.selection()
                onSettings()
            } label: {
                Text("Edit")
                    .font(TypeScale.font(TypeScale.sm, weight: .medium))
                    .foregroundStyle(Tokens.textPrimary)
                    .padding(.horizontal, 18)
                    .frame(height: 34)
                    .hermeyGlass(Capsule(), interactive: true)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(title)")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    /// Everything you can do to this bot, in groups. A panel per group and a rule between rows: a
    /// rule that runs edge to edge stops reading as a separator and starts reading as a stripe,
    /// which is what the old list had.
    private var verbs: some View {
        VStack(spacing: 14) {
            panel {
                row("Computer", systemImage: "display", run: onComputer)
                rowDivider
                row("Workspace", systemImage: "folder", run: onWorkspace)
            }

            panel {
                row("Skills", systemImage: "book.closed", run: onSkills)
                rowDivider
                row("MCP servers", systemImage: "puzzlepiece.extension", run: onMCP)
            }

            // Settings is gone from this page: Edit, in the header, opens the same sheet, and two
            // doors to one room is one door too many.
            panel {
                row("Search", systemImage: "magnifyingglass", run: onSearch)
            }

            // Compaction, the unread sweep and spoken replies are gone from this page: the first
            // two happen on their own (auto-compaction and the host's own sweep), and the third
            // belongs beside the microphone that records, not in a list of things a page can do.

            panel {
                row("Reset chat", systemImage: "arrow.counterclockwise",
                    tone: Tokens.danger, run: onReset)
            }
        }
    }

    // The swipe hint is gone: the back button is in the corner, and a page that has to tell you
    // how to leave it is a page that has not finished being a page.
    @ViewBuilder
    private var footer: some View { EmptyView() }

    /// One group of verbs: the sheet's colour, generous corners, nothing outside it.
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Tokens.sheet,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Tokens.border)
            .frame(height: 1)
            .padding(.leading, 48)
    }

    private func row(_ label: String, systemImage: String, isDisabled: Bool = false,
                     isBusy: Bool = false, tone: Color? = nil,
                     run: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            run()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(tone ?? Tokens.textSecondary)
                    .frame(width: 22)
                Text(label)
                    .font(TypeScale.font(TypeScale.md))
                    .foregroundStyle(tone ?? Tokens.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tokens.textDim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isBusy)
        .opacity(isDisabled ? 0.45 : 1)
    }
}

#if DEBUG
extension ConversationDrawer {
    /// Preview-only fixture: `PreviewFixture` has no host, so every closure is a no-op.
    static func preview() -> ConversationDrawer {
        ConversationDrawer(title: "cody", subtitle: "lead developer",
                           face: BotFace.default(for: "cody"),
                           isCompressing: false,
                           hasAnyUnread: true, canSpeak: true, speakReplies: false,
                           onComputer: {}, onWorkspace: {}, onSkills: {}, onMCP: {},
                           onSearch: {}, onSettings: {}, onCompact: {}, onMarkAllRead: {},
                           onSpeakChange: { _ in }, onReset: {}, onClose: {})
    }
}
#endif
