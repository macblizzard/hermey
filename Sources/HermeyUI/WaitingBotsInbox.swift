import Foundation
import HermesKit
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
    /// When the bot last spoke, for the row's stamp. `nil` when the device has no host time for it
    /// (a bot it has never heard from), and the row simply draws no stamp.
    public let at: Date?

    public init(id: String,
                name: String,
                count: Int,
                preview: String? = nil,
                face: String? = nil,
                at: Date? = nil) {
        self.id = id
        self.name = name
        self.count = count
        self.preview = preview
        self.face = face
        self.at = at
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
                            faces: [String: String] = [:],
                            times: [String: Date] = [:]) -> [WaitingBot] {
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
                                   face: faces[id],
                                   at: times[id]))
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
    /// The host's own update, drawn above the bots — nil for the normal case where there is none,
    /// no host, or a host that cannot update itself.
    public var hostUpdate: HostUpdate?
    public var onOpen: (String) -> Void
    /// The row's Update button. Nothing else in either app calls this.
    public var onUpdateHost: () -> Void
    /// The ✕ on a settled row (updated, rolled back, failed).
    public var onDismissHostUpdate: () -> Void

    public init(bots: [WaitingBot],
                hostUpdate: HostUpdate? = nil,
                onOpen: @escaping (String) -> Void,
                onUpdateHost: @escaping () -> Void = {},
                onDismissHostUpdate: @escaping () -> Void = {}) {
        self.bots = bots
        self.hostUpdate = hostUpdate
        self.onOpen = onOpen
        self.onUpdateHost = onUpdateHost
        self.onDismissHostUpdate = onDismissHostUpdate
    }

    /// The panel's own inset, so the rows line up with the bot list behind the popover.
    private let inset: CGFloat = 8
    /// The row's fill is inset this much inside the panel, so the highlight has a margin while the
    /// avatar, title and preview still share the header's leading edge (`inset`).
    private static let rowInset: CGFloat = 4

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
            .padding(.top, Self.headerTop)
            .padding(.bottom, 2)

            // The host's own update first: it is the only row here that is not a bot, and it is the
            // only one with something to *do* rather than read.
            if let hostUpdate {
                HostUpdateRow(update: hostUpdate,
                              onUpdate: onUpdateHost,
                              onDismiss: onDismissHostUpdate)
                    .padding(.horizontal, Self.rowInset)
                    .padding(.bottom, 2)
            }

            if bots.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(bots) { bot in
                            row(bot)
                        }
                    }
                    .padding(.horizontal, Self.rowInset)
                }
                // The list is as tall as what is waiting, capped: a popover sized from a
                // `ScrollView`'s ideal height collapses to nothing, and a fixed cap is the one
                // height that works in both a popover and a sheet.
                .frame(height: listHeight)
            }
        }
        .padding(.bottom, Self.bottomInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(iOS)
        // The sheet is content-sized (see `sheetHeight(for:)`), but its stack still pins to the
        // top: a short list centred in the sheet is the dead space the owner reported above
        // `WAITING`.
        .frame(maxHeight: .infinity, alignment: .topLeading)
        #endif
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

    /// The header's top padding. On the phone it sits right under the grab handle; on the Mac
    /// there is a popover arrow's own breathing room to keep.
    private static var headerTop: CGFloat {
        #if os(iOS)
        return 8
        #else
        return 10
        #endif
    }

    /// One row's pitch — avatar, two lines, and the gap above and below it. The phone draws the
    /// list's own row (38 pt face, 10 pt vertical padding); the popover is denser.
    private static var rowPitch: CGFloat {
        #if os(iOS)
        return Geometry.rosterRow + 1
        #else
        return 37
        #endif
    }

    /// The face and the count ride together, at the list's own sizes.
    private static var avatarSize: CGFloat {
        #if os(iOS)
        return Geometry.rosterAvatar
        #else
        return 26
        #endif
    }

    private static var badgeSize: CGFloat {
        #if os(iOS)
        return 19
        #else
        return 17
        #endif
    }

    private static var badgeNudge: CGFloat {
        #if os(iOS)
        return 5
        #else
        return 4
        #endif
    }

    /// The row's own top and bottom breathing room: the phone uses the list's 10 pt, the denser
    /// popover keeps 5.
    private static var rowPadding: CGFloat {
        #if os(iOS)
        return 10
        #else
        return 5
        #endif
    }

    /// The tallest the list grows before it scrolls. Eight Mac rows.
    private static let listCap: CGFloat = 300

    /// Bottom breathing room under the last row.
    private static let bottomInset: CGFloat = 10

    /// The drag indicator and its inset: part of a `.height` detent's measurement, none of the
    /// stack's own layout.
    private static let grabberInset: CGFloat = 24

    /// How tall the phone's sheet should be for `rowCount` rows.
    ///
    /// The sheet used to open at `.medium` whatever the list held, so one waiting bot sat under a
    /// page of empty space. The detent is the header, the rows and the footer, plus the handle;
    /// a long list still caps and scrolls rather than growing past the screen. `hostUpdate` adds the
    /// one non-bot row, which is a fixed height rather than a row pitch.
    public static func sheetHeight(for rowCount: Int, hostUpdate: Bool = false) -> CGFloat {
        let list = min(CGFloat(max(rowCount, 1)) * Self.rowPitch + 4, Self.listCap)
        let header = Self.headerTop + 12 + 2 + 6
        let update = hostUpdate ? HostUpdateRow.sheetHeight : 0
        return max(header + list + update + Self.bottomInset + Self.grabberInset, 120)
    }

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
            HStack(alignment: .center, spacing: 10) {
                BotAvatarView(identity: bot.id,
                              color: bot.face,
                              activity: .idle,
                              size: Self.avatarSize,
                              // Nothing in this list is on screen as a conversation: a row that
                              // animated would be motion with no meaning.
                              animates: false)
                    // The count sits on the face's bottom-right corner, exactly as the bot list
                    // draws it. At the row's trailing edge it read as a second object — the badge
                    // the owner saw floating far from the avatar.
                    .overlay(alignment: .bottomTrailing) {
                        UnreadBadge(count: bot.count, size: Self.badgeSize)
                            .offset(x: Self.badgeNudge, y: Self.badgeNudge - 1)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    // Name and stamp on one line, the house row's order; the preview under it.
                    HStack(spacing: 6) {
                        Text(bot.name)
                            .font(TypeScale.font(Tokens.rosterName, weight: .medium))
                            .foregroundStyle(Tokens.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let at = bot.at {
                            Text(RelativeTime.stamp(at))
                                .font(TypeScale.font(Tokens.rosterMeta))
                                .foregroundStyle(Tokens.textDim)
                                .monospacedDigit()
                                .lineLimit(1)
                                .layoutPriority(1)
                                .accessibilityLabel("last message \(RelativeTime.detailed(at))")
                        }
                    }
                    if let preview = bot.preview {
                        Text(preview)
                            .font(TypeScale.font(Tokens.rosterMeta))
                            .foregroundStyle(Tokens.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.rowInset)
            .padding(.vertical, Self.rowPadding)
            .frame(maxWidth: .infinity, minHeight: Self.rowPitch - 1, alignment: .leading)
            .hoverFill(rest: .clear, hover: Tokens.controlHover, radius: Tokens.radiusControl)
            .contentShape(Rectangle())
        }
        // Plain, so the system does not draw its own button chrome over the row's fill.
        .buttonStyle(.plain)
        // A popover hands focus to its first control, and macOS drew the blue focus ring around
        // that row as if it were selected. The ring is suppressed, not the focus: Space/Return on
        // a focused row still opens it for a keyboard user, and the hover fill is the visible
        // feedback for everyone else.
        .hermeyFocusQuiet()
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
