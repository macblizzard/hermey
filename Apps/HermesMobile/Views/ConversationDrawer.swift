import SwiftUI
import HermesAppKit
import OpenBotUI

/// A conversation's verbs as a page, opened by dragging in from the right edge.
///
/// The bar's ⋯ is gone on purpose (reported 2026-11-12): a chat already owns the whole screen, so
/// its verbs get a door that is bigger than a 22 pt glyph — a swipe from the trailing edge, which is
/// the one gesture a phone chat was not using. Same list, same order, same verbs as the menu it
/// replaces; the bot *list* keeps its own ⋯, because that screen has nothing to swipe over.
///
/// The page is a full-height panel rather than a sheet: a sheet would cover the conversation with a
/// rounded card and slide the whole screen, and this is a panel belonging to the chat it came from.
struct ConversationDrawer: View {
    let title: String
    let subtitle: String?
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

    /// Most of the phone: a row's label is never truncated, and a strip of the conversation stays
    /// visible to say where this came from. Measured, never taken from `UIScreen` — a split-screen
    /// iPad or a widened window is not the phone's width.
    private static let widthFraction: CGFloat = 0.78

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // Tapping the dimmed conversation closes the panel, the way every iOS drawer works.
                Color.black.opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture { onClose() }
                    .accessibilityLabel("Close the conversation actions")

                panel
                    .frame(width: max(220, geo.size.width * Self.widthFraction))
                    // The theme's sheet, not its raised surface: `surface` is the colour of a card
                    // inside the conversation, and a whole panel of it read as a grey slab pasted
                    // over a near-black chat. A sheet is one step off the canvas, and the shadow
                    // does the work of separating it.
                    .background(Tokens.sheet)
                    .overlay(alignment: .leading) { Hairline(color: Tokens.border) }
                    .shadow(color: .black.opacity(0.45), radius: 24, x: -10, y: 0)
                    .gesture(
                        // Swipe back out the way it came in. Vertical-drift guard so a scroll inside
                        // the panel is not read as a dismissal.
                        DragGesture(minimumDistance: 18)
                            .onEnded { value in
                                if value.translation.width > 60,
                                   abs(value.translation.height) < abs(value.translation.width) {
                                    onClose()
                                }
                            }
                    )
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .transition(.move(edge: .trailing))
        .accessibilityAddTraits(.isModal)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TypeScale.font(TypeScale.sessionTitle, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(TypeScale.font(TypeScale.micro))
                        .foregroundStyle(Tokens.textDim)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Geometry.chatGutter)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Hairline(color: Tokens.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // What the bot works with, then what it made, then the two panels about reach.
                    row("Computer", systemImage: "display", run: onComputer)
                    row("Workspace", systemImage: "folder", run: onWorkspace)
                    section
                    row("Skills", systemImage: "book.closed", run: onSkills)
                    row("MCP servers", systemImage: "puzzlepiece.extension", run: onMCP)
                    section
                    row("Search", systemImage: "magnifyingglass", run: onSearch)
                    row("Settings", systemImage: "gearshape", run: onSettings)
                    row(isCompressing ? "Compacting…" : "Compact",
                        systemImage: isCompressing ? "hourglass" : "arrow.down.right.and.arrow.up.left",
                        isBusy: isCompressing,
                        run: onCompact)
                    section
                    row("Mark all as read", systemImage: "checkmark.circle",
                        isDisabled: !hasAnyUnread, run: onMarkAllRead)
                    speakRow
                    section
                    row("Reset chat", systemImage: "arrow.counterclockwise",
                        tone: Tokens.danger, run: onReset)

                    // Inside the list, not under it: a line pinned to the panel's bottom edge stayed
                    // put while the menu scrolled past it, which read as a rule drawn over the
                    // "Compact" row.
                    section
                    Text("Swipe right, or tap outside, to close")
                        .font(TypeScale.font(TypeScale.micro))
                        .foregroundStyle(Tokens.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Geometry.chatGutter)
                        .padding(.top, 10)
                }
                .padding(.bottom, 24)
            }
        }
    }

    private var section: some View {
        Rectangle()
            .fill(Tokens.border)
            .frame(height: 1)
            .padding(.horizontal, Geometry.chatGutter)
            .padding(.vertical, 6)
    }

    /// One verb. A switch with a name is its own row, because the two things it does — remember the
    /// choice, and stop the voice that is already talking — are not a tap on a button.
    private var speakRow: some View {
        Toggle(isOn: Binding(get: { speakReplies }, set: { onSpeakChange($0) })) {
            Label {
                Text("Speak replies")
                    .font(TypeScale.font(TypeScale.md))
                    .foregroundStyle(Tokens.textPrimary)
            } icon: {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 15))
                    .foregroundStyle(Tokens.textSecondary)
                    .frame(width: 22)
            }
        }
        .tint(Tokens.accentText)
        .disabled(!canSpeak)
        .opacity(canSpeak ? 1 : 0.45)
        .padding(.horizontal, Geometry.chatGutter)
        .padding(.vertical, 11)
    }

    private func row(_ label: String, systemImage: String, isDisabled: Bool = false,
                     isBusy: Bool = false, tone: Color? = nil, run: @escaping () -> Void) -> some View {
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Geometry.chatGutter)
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
        ConversationDrawer(title: "cody", subtitle: "lead developer", isCompressing: false,
                           hasAnyUnread: true, canSpeak: true, speakReplies: false,
                           onComputer: {}, onWorkspace: {}, onSkills: {}, onMCP: {},
                           onSearch: {}, onSettings: {}, onCompact: {}, onMarkAllRead: {},
                           onSpeakChange: { _ in }, onReset: {}, onClose: {})
    }
}
#endif
