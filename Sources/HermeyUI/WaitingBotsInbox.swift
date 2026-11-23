import Foundation
import SwiftUI

/// One bot with replies the user has not looked at yet — the row a notification list is built from.
///
/// This is a *view* of `AppModel`'s unread state, not a second record of it: the ids and counts come
/// from `unreadCounts` / `unreadBots` (the host's own numbers), the name from the roster, and the
/// line under the name from the preview cache the bot list already keeps (`bots/previews`). Nothing
/// here counts anything of its own, so a badge cannot disagree with this list.
public struct WaitingBot: Identifiable, Equatable, Sendable {
    /// The profile name, which is also the bot's identity everywhere else in both apps.
    public let id: String
    /// What to draw as the row's title: the roster's display name, or the id when the roster has
    /// not answered yet.
    public let name: String
    /// How many of the bot's turns landed after this device last looked. Always at least 1: a row
    /// that exists with a count of 0 would be a row that should not exist.
    public let count: Int
    /// The first line of the bot's newest message, flattened — `nil` when the preview cache has
    /// nothing for it (a bot this device has never heard from).
    public let preview: String?
    /// The stored face (`#RRGGBB::shape_N`), so the row draws the same avatar the bot list does.
    public let face: String?

    public init(id: String,
                name: String,
                count: Int,
                preview: String? = nil,
                face: String? = nil) {
        self.id = id
        self.name = name
        self.count = count
        self.preview = preview
        self.face = face
    }

    /// What VoiceOver says about the count, so the number is not read as part of the name.
    public var waitingLabel: String {
        count == 1 ? "1 new reply" : "\(count) new replies"
    }
}

/// The waiting list's rules, in one place so the Mac's popover and the phone's sheet cannot order
/// or filter the same bots differently.
public enum WaitingBots {
    /// Longest preview line drawn. A row is one line: past this the text is elided anyway, and the
    /// cut happens here so the ellipsis lands on a character, not mid-word in the drawing layer.
    public static let previewLimit = 140

    /// Every bot with something waiting, most waiting first.
    ///
    /// `unread` and `counts` are `AppModel`'s two statements of the same fact and both are taken:
    /// the set is what the dot is drawn from and survives a failed count sweep, the dictionary is
    /// the exact number. A bot in neither has nothing waiting and is not a row.
    ///
    /// Sorted by count (descending), then by name (case-insensitively), then by id — so two bots
    /// with one reply each always land in the same order on both devices.
    public static func rows(unread: Set<String>,
                            counts: [String: Int],
                            names: [String: String],
                            previews: [String: String] = [:],
                            faces: [String: String] = [:]) -> [WaitingBot] {
        var rows: [WaitingBot] = []
        for id in Set(unread).union(counts.keys) {
            // A swept count of zero means "nothing waiting" even if the dot is still up: the dot
            // is the weaker statement, and this list is a list of replies.
            let count = counts[id] ?? 1
            guard count > 0 else { continue }
            rows.append(WaitingBot(id: id,
                                   name: names[id] ?? id,
                                   count: count,
                                   preview: firstLine(previews[id]),
                                   face: faces[id]))
        }
        rows.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }
        return rows
    }

    /// The first line of a preview, flattened to one line and bounded.
    ///
    /// `bots/previews` sends the newest message whole, newlines and all; a row is one line, so the
    /// break is taken here and runs of whitespace collapse (a transcript message often starts with
    /// an indented code block, which would otherwise draw as an empty row).
    public static func firstLine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let firstNewline = raw.firstIndex(where: { $0.isNewline })
        let head = firstNewline.map { String(raw[raw.startIndex..<$0]) } ?? raw
        let collapsed = head.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > previewLimit else { return trimmed }
        return String(trimmed.prefix(previewLimit)) + "…"
    }
}

/// The list itself: one row per bot with replies waiting, drawn the same in the Mac's popover and
/// the phone's sheet.
///
/// Tapping a row is the whole interaction — the caller selects the bot and clears its badge — so the
/// row is a button and nothing else. The list never scrolls itself into a page: it is as tall as
/// what is waiting, and the caller gives it a bound.
public struct WaitingBotsInbox: View {
    public var bots: [WaitingBot]
    public var onOpen: (String) -> Void

    public init(bots: [WaitingBot], onOpen: @escaping (String) -> Void) {
        self.bots = bots
        self.onOpen = onOpen
    }

    /// The panel's own inset, so the rows line up with the bot list behind the popover.
    private let inset: CGFloat = 8

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SectionCaption("WAITING")
                Spacer(minLength: 0)
                if !bots.isEmpty {
                    Text(summary)
                        .font(TypeScale.font(Tokens.rosterMeta))
                        .foregroundStyle(Tokens.textDim)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, inset)
            .padding(.top, 10)
            .padding(.bottom, 2)

            if bots.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(bots) { bot in
                            row(bot)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                // The list is as tall as what is waiting, capped: a popover sized from a
                // `ScrollView`'s ideal height collapses to nothing, and a fixed cap is the one
                // height that works in both a popover and a sheet.
                .frame(height: listHeight)
            }
        }
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill)
    }

    /// The surface this list sits on. On the Mac it is a popover over the bot panel, so it wears the
    /// panel's own fill; on the phone it is a house sheet, so it wears the canvas every sheet wears.
    private var fill: Color {
        #if os(macOS)
        return Tokens.sidebar
        #else
        return Tokens.canvas
        #endif
    }

    /// One row's pitch — avatar, two lines, and the gap above and below it.
    private static let rowPitch: CGFloat = 42
    /// The tallest the list grows before it scrolls. Seven rows.
    private static let listCap: CGFloat = 300

    private var listHeight: CGFloat {
        min(CGFloat(bots.count) * Self.rowPitch + 4, Self.listCap)
    }

    /// Bots, not replies: "2 waiting" is a statement about what the list holds, and the numbers on
    /// the rows say how much.
    private var summary: String {
        bots.count == 1 ? "1 bot" : "\(bots.count) bots"
    }

    private func row(_ bot: WaitingBot) -> some View {
        Button { onOpen(bot.id) } label: {
            HStack(spacing: 9) {
                BotAvatarView(identity: bot.id,
                              color: bot.face,
                              activity: .idle,
                              size: 26,
                              // Nothing in this list is on screen as a conversation: a row that
                              // animated would be motion with no meaning.
                              animates: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bot.name)
                        .font(TypeScale.font(Tokens.rosterName, weight: .medium))
                        .foregroundStyle(Tokens.textPrimary)
                        .lineLimit(1)
                    if let preview = bot.preview {
                        Text(preview)
                            .font(TypeScale.font(Tokens.rosterMeta))
                            .foregroundStyle(Tokens.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                UnreadBadge(count: bot.count, size: 17)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .modifier(WaitingRowHint(name: bot.name))
        .accessibilityLabel(bot.preview.map { "\(bot.name), \(bot.waitingLabel), \($0)" }
                            ?? "\(bot.name), \(bot.waitingLabel)")
        .accessibilityIdentifier("waiting.bot.\(bot.id)")
    }

    private var emptyState: some View {
        Text("Nothing waiting.")
            .font(TypeScale.font(Tokens.textSM))
            .foregroundStyle(Tokens.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset)
            .padding(.vertical, 8)
            .accessibilityIdentifier("waiting.empty")
    }
}

/// The row's tooltip, where tooltips exist.
///
/// A `.help` is a Mac affordance; the phone has no hover, and the same words are already in the
/// row's accessibility label. A modifier rather than an `#if` inside the row's chain, so the row's
/// shape does not change with the platform.
private struct WaitingRowHint: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        #if os(macOS)
        content.help("Open \(name)")
        #else
        content
        #endif
    }
}

/// The dot a bell wears while the list is not empty.
///
/// One definition for both apps, because it is the same promise in both places: something is
/// waiting, and the count is one tap away. Drawn as an overlay so it never changes the button's
/// size — the top row's spacing must not move when a reply lands.
public struct WaitingDot: ViewModifier {
    private let visible: Bool
    private let size: CGFloat

    public init(visible: Bool, size: CGFloat = 5) {
        self.visible = visible
        self.size = size
    }

    public func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if visible {
                Circle()
                    .fill(Tokens.success)
                    .frame(width: size, height: size)
                    // A hairline of the panel behind it keeps the dot legible over the glyph.
                    .overlay(Circle().strokeBorder(Tokens.sidebar, lineWidth: 1))
                    .padding(3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

public extension View {
    /// Mark a button as "there is something waiting behind this". See `WaitingDot`.
    func waitingDot(_ visible: Bool, size: CGFloat = 5) -> some View {
        modifier(WaitingDot(visible: visible, size: size))
    }
}

#if DEBUG
#Preview("Waiting bots") {
    WaitingBotsInbox(
        bots: WaitingBots.rows(unread: ["cody", "ops"],
                               counts: ["cody": 3, "ops": 1, "garden": 9],
                               names: ["cody": "Cody", "ops": "Ops", "garden": "Garden"],
                               previews: ["cody": "The deploy is green.\nSecond line dropped.",
                                          "ops": "Two reviews are waiting."]),
        onOpen: { _ in })
        .frame(width: 300)
        .preferredColorScheme(.dark)
}

#Preview("Waiting bots · empty") {
    WaitingBotsInbox(bots: [], onOpen: { _ in })
        .frame(width: 300)
        .preferredColorScheme(.dark)
}
#endif
