import SwiftUI

/// The OpenBot design system.
///
/// Every value here is a direct port of `packages/brand/src/tokens.css` from the
/// OpenBot clone (dark palette). That file is the single declaration site upstream;
/// this one is its Swift mirror. Do not add a colour anywhere else in the app — if a
/// component needs a new shade, add the token here first, with the upstream name in
/// the comment, so the two files can be diffed.
///
/// Colours are **computed**: each one reads the active `ThemePalette`, so a theme change is a value
/// in `ThemeCatalog` rather than a pass over every view. Radius and type are fixed — a theme is
/// colour, not geometry.
public enum Tokens {

    // MARK: Surfaces
    public static var canvas: Color { ThemeRuntime.active.canvas }
    public static var frame: Color { ThemeRuntime.active.frame }
    public static var sidebar: Color { ThemeRuntime.active.sidebar }
    public static var surface: Color { ThemeRuntime.active.surface }
    public static var surfaceRaised: Color { ThemeRuntime.active.surfaceRaised }
    public static var control: Color { ThemeRuntime.active.control }
    public static var controlHover: Color { ThemeRuntime.active.controlHover }
    public static var controlActive: Color { ThemeRuntime.active.controlActive }
    public static var sheet: Color { ThemeRuntime.active.sheet }
    public static var sheetInset: Color { ThemeRuntime.active.sheetInset }
    public static var grouped: Color { ThemeRuntime.active.grouped }

    // MARK: Text
    public static var textPrimary: Color { ThemeRuntime.active.textPrimary }
    public static var textSecondary: Color { ThemeRuntime.active.textSecondary }
    public static var textMuted: Color { ThemeRuntime.active.textMuted }
    public static var textDim: Color { ThemeRuntime.active.textDim }
    public static var textPlaceholder: Color { ThemeRuntime.active.textPlaceholder }
    public static var textGroupedSecondary: Color { ThemeRuntime.active.textGroupedSecondary }

    // MARK: Accent and status
    public static var accent: Color { ThemeRuntime.active.accent }
    public static var accentHover: Color { ThemeRuntime.active.accentHover }
    public static var accentText: Color { ThemeRuntime.active.accentText }
    /// The accent as a wash behind a selected row. Derived, so a theme's accent tints its own
    /// selection instead of keeping the default blue's.
    public static var accentSoft: Color { accent.opacity(0.16) }
    public static var success: Color { ThemeRuntime.active.success }
    public static var successSoft: Color { success.opacity(0.12) }
    public static var warning: Color { ThemeRuntime.active.warning }
    public static var warningSoft: Color { warning.opacity(0.12) }
    public static var danger: Color { ThemeRuntime.active.danger }
    public static var dangerSoft: Color { danger.opacity(0.16) }

    // MARK: Borders
    public static var border: Color { ThemeRuntime.active.border }
    public static var borderStrong: Color { ThemeRuntime.active.borderStrong }
    public static var borderGrouped: Color { ThemeRuntime.active.borderGrouped }
    public static var borderFocus: Color { ThemeRuntime.active.textMuted }

    // MARK: Radius
    //
    // Rakazo's radius chain (`--radius: 0.75rem`, remapped utilities): rows and cards 16, bubbles 20,
    // the composer bar 26, popovers 14. `radiusCard` moved 12 → 16 and `radiusControl` 9 → 10 so
    // every existing surface lands on the same steps without a per-view number.
    public static let radiusGrouped: CGFloat = 16
    public static let radiusCard: CGFloat = 16
    public static let radiusControl: CGFloat = 10
    public static let radiusSmall: CGFloat = 8
    /// Message bubbles, the reaction popover and the large dialogs.
    public static let radiusBubble: CGFloat = 20
    /// The composer bar's own pill.
    public static let radiusComposer: CGFloat = 26
    /// The mention/slash picker above the composer.
    public static let radiusPicker: CGFloat = 14

    // MARK: Type scale (--openbot-text-sm/md/lg/xl)
    public static let textSM: CGFloat = 12
    public static let textMD: CGFloat = 13
    public static let textLG: CGFloat = 14
    public static let textXL: CGFloat = 16

    /// Chat body. Rakazo draws a message at 15 pt on a 22 pt line
    /// (`text-body-lg` in `packages/ui-web/src/styles.css`); the phone keeps iOS's 17/22.
    public static let chatBodyMacOS: CGFloat = 15
    public static let chatBodyIOS: CGFloat = 17
    public static let chatLineIOS: CGFloat = 22
    /// The line height the Mac's transcript and composer share with `chatBodyMacOS`.
    public static let chatLineMacOS: CGFloat = 22

    /// Roster type: the name is 13/18, its preview and timestamp 12/16.
    public static let rosterName: CGFloat = 13
    public static let rosterMeta: CGFloat = 12
    /// The floating chat header's one title line: 15/22 medium.
    public static let chatHeaderTitle: CGFloat = 15

    public static let mono = Font.system(size: 11.5, weight: .regular, design: .monospaced)
}

// MARK: - Geometry (src/renderer/src/layout-constants.ts)

public enum Geometry {
    public static let serverRailMacOS: CGFloat = 72      // MAC_SERVER_RAIL_WIDTH
    public static let serverRail: CGFloat = 64           // SERVER_RAIL_WIDTH
    public static let serverRailNarrow: CGFloat = 56     // NARROW_SERVER_RAIL_WIDTH
    // Rakazo's bots sidebar (`apps/web/src/lib/bots-sidebar-pref.ts`): 316 default, 240 floor,
    // 480 ceiling, 72 when collapsed to icons, and a drag below 160 snaps shut.
    public static let sidebarDefault: CGFloat = 316      // BOTS_SIDEBAR_DEFAULT_WIDTH
    public static let sidebarMin: CGFloat = 240          // BOTS_SIDEBAR_MIN_WIDTH
    public static let sidebarMax: CGFloat = 480          // BOTS_SIDEBAR_MAX_WIDTH
    public static let sidebarCompact: CGFloat = 72       // BOTS_SIDEBAR_MINI_WIDTH
    public static let sidebarCollapseBelow: CGFloat = 160  // BOTS_SIDEBAR_SNAP_WIDTH
    public static let conversationMin: CGFloat = 424     // CONVERSATION_MIN_WIDTH
    /// The bot panel's width when it opens (`ResizableSidePanel` DEFAULT_WIDTH 384).
    public static let contextPanel: CGFloat = 384
    /// The reading column: 960 pt, centred, with a 28 pt minimum gutter
    /// (`apps/web/src/lib/transcript-layout.ts` — `calc((100% - 60rem)/2)`).
    public static let conversationMeasure: CGFloat = 960
    /// One inset for the conversation column: header, transcript, approval cards, composer and
    /// error strips all start here, so their left edges cannot drift apart. Rakazo's transcript
    /// gutter; the composer sits at `composerInset`.
    public static let readingInset: CGFloat = 28
    /// The composer's own minimum gutter, 4 pt tighter than the transcript's on purpose
    /// (`composer.tsx` uses `1.5rem` where the transcript uses `1.75rem`).
    public static let composerInset: CGFloat = 24
    /// One inset for the bot panel: its header, rows, empty states and host chip agree.
    public static let sidebarInset: CGFloat = 12
    /// The window's own rounded clip, and the floating palette's.
    public static let radiusWindow: CGFloat = 12
    public static let radiusPalette: CGFloat = 16
    /// The divider between the bot panel and the conversation (hit area, not visual width).
    public static let paneDivider: CGFloat = 7

    /// The one gutter a conversation draws **both** its bubbles and its composer at: the Mac's 28 pt
    /// reading inset, the phone's 16 (a 393 pt screen cannot spare 28 on both sides).
    public static var chatGutter: CGFloat {
        #if os(macOS)
        return readingInset
        #else
        return 16
        #endif
    }

    // MARK: The roster (Rakazo §2.6)

    /// A chat row's height: avatar 38 + 2×10 padding.
    public static let rosterRow: CGFloat = 58
    public static let rosterAvatar: CGFloat = 38
    public static let rosterAvatarCompact: CGFloat = 28
    public static let rosterAvatarMini: CGFloat = 40
    /// Row padding: 10 pt horizontal, 10 pt vertical, 12 pt between avatar and text.
    public static let rosterRowPadding: CGFloat = 10
    public static let rosterRowGap: CGFloat = 12
    /// The list's own padding and the 2 pt between rows.
    public static let rosterListPadding: CGFloat = 10
    public static let rosterRowSpacing: CGFloat = 2
    /// The header's row: 18 pt sides, 16 top, 12 bottom, 28 pt buttons ⇒ 56 pt tall.
    public static let sidebarHeaderTop: CGFloat = 16
    public static let sidebarHeaderBottom: CGFloat = 12
    public static let sidebarHeaderInset: CGFloat = 18
    public static let sidebarHeaderButton: CGFloat = 28
    /// The search field: 36 pt tall, 16 pt radius, 10 pt side margins.
    public static let sidebarSearchHeight: CGFloat = 36
    public static let sidebarSearchMargin: CGFloat = 10

    // MARK: The chat header (Rakazo §3)

    /// Not a bar — a 62 pt floating row over the transcript: 36 pt pills plus 13 pt top and bottom.
    public static let chatHeader: CGFloat = 62
    public static let chatHeaderAvatar: CGFloat = 28
    // 40 rather than 36: the pill carries the bot's state on its face now, so the face needs the
    // pixels the status chip used to get. The transcript's top inset is derived from this, so the
    // rows move with it rather than under it.
    public static let chatHeaderPill: CGFloat = 40
    /// The transcript reserves this much room for the floating header, plus scroll padding.
    public static let transcriptTopInset: CGFloat = 84
    public static let transcriptBottomInset: CGFloat = 52

    // MARK: The transcript (Rakazo §4)

    /// Every message sits 8 pt below the one before it — no extra air between turns.
    public static let transcriptRowSpacing: CGFloat = 8
    /// A bubble's own padding: 18 pt horizontal, 12 pt vertical.
    public static let bubblePaddingH: CGFloat = 18
    public static let bubblePaddingV: CGFloat = 12
    /// A user bubble may take 84% of the column, a bot's 88%, both capped at 624 pt.
    public static let userBubbleFraction: CGFloat = 0.84
    public static let botBubbleFraction: CGFloat = 0.88
    public static let bubbleMaxWidth: CGFloat = 624

    // MARK: The composer (Rakazo §5)

    /// Resting height: 32 pt control + 18 pt padding + 2 pt border.
    public static let composerHeight: CGFloat = 52
    public static let composerButton: CGFloat = 32
    public static let composerTextMaxHeight: CGFloat = 100
}

// MARK: - Helpers

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

public extension View {
    /// The 1 px hairline every OpenBot surface uses.
    func hairlineBorder(_ radius: CGFloat = Tokens.radiusCard) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Tokens.borderStrong, lineWidth: 1)
        )
    }
}
