// The OpenBotUI component library.
//
// Every screen in both apps is assembled from these pieces; a screen supplies content
// and state, never a colour, radius, font size or duration. The inventory:
//
//   Avatar          idle / running / needs-you, four sizes
//   SessionRow      normal, selected, unread, running progress (macOS + iOS density)
//   StatusChip      transport / model / reasoning / queue count
//   ToolCard        running / done / failed, collapsed over 12 lines, expands in place
//   ApprovalCard    pending (three answers) / answered receipt / expired
//   Composer        empty / typing / sending (interrupt) / disabled / queued
//   ContextGauge    ok / warn > 70% / compact > 85%, ring or bar
//   ConnectionBanner reconnecting / offline / protocol mismatch
//   GroupedListRow  + GroupedSection: the 16 pt grouped card
//   OpenBotButton   primary / secondary / ghost / danger, 44 pt hit target on iOS
//   Hairline, TypeScale, Motion, Haptics, RelativeTime — the shared decisions
//
// Values come from Tokens.swift only. Platform-only APIs are behind #if; the density
// differences (13 pt vs 15 pt titles, 26 pt vs 44 pt avatars) are the spec's two
// typography tables, not a drift.

import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Type scale

/// The type scale the components draw with.
///
/// The sizes are the token values from `Tokens` (10–16 pt, never larger inside UI
/// chrome); the platform constants are the two rows of the UX spec's typography table,
/// which are the desktop and mobile tables OpenBot keeps separately
/// (`chat-text-styles.ts`). Nothing here invents a size.
public enum TypeScale {
    /// Section captions and the smallest meta line. `--openbot-text-*` starts at 12, so
    /// 10 and 11 are the two label steps the desktop uses below it.
    public static let caption: CGFloat = 10
    /// Glyphs and the smallest secondary text; nothing in the app should be smaller.
    public static let micro: CGFloat = 9
    public static let label: CGFloat = 11

    public static let sm: CGFloat = Tokens.textSM
    public static let md: CGFloat = Tokens.textMD
    public static let lg: CGFloat = Tokens.textLG
    public static let xl: CGFloat = Tokens.textXL

    /// The user's text size, from ⌘+ / ⌘- (or the phone's Settings). 1 is the design system's own.
    ///
    /// `nonisolated(unsafe)`: read from view bodies on the main thread; written only by the size
    /// commands, which re-create the view tree the same way a theme change does.
    public nonisolated(unsafe) static var factor: CGFloat = 1

    /// The steps ⌘+ / ⌘- walk through. Two of them are below 1 on purpose: a small window wants
    /// smaller text, and the design system's sizes assume a 1240 pt window.
    public static let steps: [CGFloat] = [0.85, 0.9, 0.95, 1, 1.06, 1.12, 1.2, 1.3]
    public static let scaleDefaultsKey = "hermey.textScale"

    public static func restoreScale() {
        let saved = UserDefaults.standard.double(forKey: scaleDefaultsKey)
        factor = saved > 0 ? saved : 1
    }

    /// Move one step and remember it. Returns the new factor.
    @discardableResult
    public static func stepSize(_ direction: Int) -> CGFloat {
        let current = steps.enumerated().min { abs($0.element - factor) < abs($1.element - factor) }?.offset ?? 3
        let index = min(max(current + direction, 0), steps.count - 1)
        factor = steps[index]
        UserDefaults.standard.set(Double(factor), forKey: scaleDefaultsKey)
        return factor
    }

    #if os(macOS)
    /// Session title 13/500/18, preview 11/400/15, body 14/1.62.
    public static let sessionTitle: CGFloat = 13
    public static let sessionPreview: CGFloat = 11
    public static var chatBody: CGFloat { Tokens.chatBodyMacOS * factor }
    public static var chatLine: CGFloat { 22.7 * factor }
    #else
    /// Session title 15/600/20, preview 13/400/17, body 16/22.
    public static let sessionTitle: CGFloat = 15
    public static let sessionPreview: CGFloat = 13
    public static var chatBody: CGFloat { Tokens.chatBodyIOS * factor }
    public static var chatLine: CGFloat { Tokens.chatLineIOS * factor }
    #endif

    /// SwiftUI lays a line out at roughly 1.2 × point size; this is the extra leading
    /// that reaches the spec's line height (22 pt on iOS, 1.62 on the desktop).
    public static var chatLineSpacing: CGFloat { max(0, chatLine - chatBody * 1.2) }

    /// Inter when the family is actually available, the system font otherwise — and always at the
    /// weight asked for.
    ///
    /// Two faults made every word on the Mac look washed out:
    ///
    /// * **The weight was thrown away.** `.custom("Inter", size:)` cannot take a `Font.Weight`, so the
    ///   parameter was accepted and never used: all 64 call sites that asked for `.semibold` or
    ///   `.medium` drew the regular face, and headings, titles and buttons had no weight contrast at
    ///   all.
    /// * **Inter is not bundled**, so `.custom` fell back to the system font anyway — a silent
    ///   downgrade to the *regular* system face. Asking for a family the app does not ship buys
    ///   nothing; asking for the system face with the right weight is what the fallback was meant to
    ///   be.
    ///
    /// The size is also rounded to a half point: the scale steps are 0.85…1.3, and 13.42 pt draws
    /// soft, unhinted glyphs on a 1× display and muddy ones even at 2×.
    public static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let points = pointSize(size)
        if interIsInstalled {
            return .custom("Inter", size: points).weight(weight)
        }
        return .system(size: points, weight: weight)
    }

    /// The size a step actually draws at: the design size times the user's step, on a half-point grid
    /// so the glyphs stay hinted.
    public static func pointSize(_ size: CGFloat) -> CGFloat {
        max(1, (size * factor * 2).rounded() / 2)
    }

    /// Whether this app can actually draw Inter. Building a `Font` from an absent family is not an
    /// error in SwiftUI — it silently renders the default face, which is how the weight went missing
    /// without anybody noticing.
    private static let interIsInstalled: Bool = {
        #if os(macOS)
        return NSFontManager.shared.availableFontFamilies.contains("Inter")
        #elseif os(iOS)
        return UIFont.familyNames.contains("Inter")
        #else
        return false
        #endif
    }()
}

// MARK: - Motion

/// The four motions the spec actually specifies. Screens use these names instead of
/// inventing a duration, so "smooth" stays a number rather than a vibe.
public enum Motion {
    /// A new message: 220–340 ms spring, 12 pt rise.
    public static let messageIn = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// Tool card appear/collapse: 180 ms ease-out.
    public static let toolCard = Animation.easeOut(duration: 0.18)
    /// Approval arrival: 240 ms, scale 0.98 → 1.
    public static let approvalArrival = Animation.spring(response: 0.24, dampingFraction: 0.92)
    /// Send and press: 120 ms.
    public static let press = Animation.easeOut(duration: 0.12)
    /// What every motion above becomes under Reduce Motion: a short cross-fade.
    public static let reduced = Animation.easeInOut(duration: 0.12)
}

// MARK: - Haptics

/// The one haptics entry point. Screens call this; they never import UIKit or AppKit
/// for feedback themselves, so the two apps cannot drift apart.
public enum Haptics {
    public static func selection() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #endif
    }

    public static func impact() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #endif
    }

    public static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #endif
    }

    public static func error() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #endif
    }

    /// Approval arrival: exactly once per request, from the screen that inserts the card.
    /// Cards must not fire this on `onAppear` — a card recycled inside a lazy stack would
    /// buzz every time it scrolls back into view.
    public static func approvalArrived() {
        impact()
    }
}

// MARK: - Time

/// Relative timestamps for session rows. One implementation, so a row on the Mac and a
/// row on the phone never disagree about what "3h" means.
public enum RelativeTime {
    /// `now`, `4m`, `3h`, `1d`, `6d`, then an abbreviated date.
    public static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        if calendar.isDateInYesterday(date) { return "1d" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The clock reading itself, for a list row: `09:25` today, `Yesterday`, the weekday inside the
    /// last six days, else `7 Nov` (with the year once it is no longer this one).
    ///
    /// Deliberately not relative. "3h" answers how urgent a row is but never what it says on the
    /// clock, and the owner asked for the time a message arrived — a row that says `09:25` can be
    /// matched against a memory, a schedule or a log line, which `3h` cannot.
    public static func stamp(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute())
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                              to: calendar.startOfDay(for: now)).day,
           days > 1, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// `14:32` today, `Yesterday 14:32`, else `4 Nov 14:32`. Used on receipts and rows
    /// where the exact minute matters.
    public static func detailed(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))) \(time)"
    }
}

// MARK: - Rules and surfaces

/// The 1 px hairline every OpenBot surface uses. `Divider` is two points on Retina and
/// a different colour on each platform; this is exactly one device pixel of one token.
public struct Hairline: View {
    public enum Axis { case horizontal, vertical }

    private let axis: Axis
    private let color: Color

    public init(_ axis: Axis = .horizontal, color: Color = Tokens.border) {
        self.axis = axis
        self.color = color
    }

    public var body: some View {
        let width: CGFloat? = axis == .vertical ? 1 : nil
        let height: CGFloat? = axis == .horizontal ? 1 : nil
        Rectangle()
            .fill(color)
            .frame(width: width, height: height)
    }
}

public extension View {
    /// A raised card: the surface fill plus its hairline. The two always travel together,
    /// so no screen can produce a card with one and not the other.
    func cardSurface(_ radius: CGFloat = Tokens.radiusCard, fill: Color = Tokens.surface) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .hairlineBorder(radius)
    }

    /// A grouped (settings-style) surface on the sheet palette: 16 pt corners.
    func groupedSurface(_ radius: CGFloat = Tokens.radiusGrouped) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Tokens.grouped))
            .hairlineBorder(radius)
    }

    /// Hover only exists where there is a pointer. Call sites stay identical on both
    /// platforms, and iOS simply never fires it.
    @ViewBuilder func onHoverCompat(_ action: @escaping (Bool) -> Void) -> some View {
        #if os(macOS)
        self.onHover(perform: action)
        #else
        self
        #endif
    }
}

/// Fill that changes under the pointer on the Mac and does nothing on iOS.
public struct HoverFill: ViewModifier {
    private let rest: Color
    private let hover: Color
    private let radius: CGFloat

    @State private var hovering = false

    public init(rest: Color, hover: Color, radius: CGFloat = Tokens.radiusControl) {
        self.rest = rest
        self.hover = hover
        self.radius = radius
    }

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(hovering ? hover : rest)
            )
            .onHoverCompat { hovering = $0 }
    }
}

public extension View {
    func hoverFill(rest: Color = .clear,
                   hover: Color = Tokens.controlHover,
                   radius: CGFloat = Tokens.radiusControl) -> some View {
        modifier(HoverFill(rest: rest, hover: hover, radius: radius))
    }
}

// MARK: - Progress

/// The 2 pt bar a running row carries. It moves so "running" is not colour alone
/// (colour-blind safe), and it stops moving under Reduce Motion.
public struct IndeterminateProgressBar: View {
    private let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    public init(height: CGFloat = 2) {
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.controlActive)
                Capsule()
                    .fill(Tokens.accent)
                    .frame(width: max(8, geo.size.width * 0.32))
                    .offset(x: reduceMotion ? 0 : (phase ? geo.size.width * 0.68 : 0))
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
        .accessibilityHidden(true)
    }
}

/// The running glyph: a quarter arc, turning. Same shape on both platforms, so a tool
/// card looks identical on the Mac and the phone.
public struct SpinningRing: View {
    private let color: Color
    private let size: CGFloat
    private let lineWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The angle, moved by a timer rather than by an animation.
    ///
    /// Two earlier versions did not spin on macOS: `withAnimation(.repeatForever)` from `onAppear`
    /// (a request the animation system may drop) and `TimelineView(.animation)` (which does not
    /// tick in this hosting view). A 30 Hz run-loop timer is not an animation to be cancelled — it
    /// is state that keeps arriving — so the ring moves wherever the view is drawn.
    @State private var degrees: Double = 0

    /// One 30 Hz publisher for the whole app. As a stored property each ring made its own — the bot
    /// lists draw one per running row, so a busy host ran a dozen independent timers to rotate a
    /// dozen circles in step anyway.
    private static let ticker = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    public init(color: Color = Tokens.accent, size: CGFloat = 10, lineWidth: CGFloat = 1.5) {
        self.color = color
        self.size = size
        self.lineWidth = lineWidth
    }

    public var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(degrees))
            // Reduce Motion slows the ring instead of freezing it: a still ring beside "is
            // working…" reads as a decoration, and this is the only sign a turn is alive.
            .opacity(reduceMotion ? 0.8 : 1)
            .onReceive(Self.ticker) { _ in
                degrees = (degrees + (reduceMotion ? 4 : 12)).truncatingRemainder(dividingBy: 360)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Captions and disclosure

/// A section caption above a group or a pane. Never uppercase-transformed here — the
/// grouped-sheet rules ask for normal casing; a pane that wants `CONTEXT` passes it.
public struct SectionCaption: View {
    private let text: String
    private let color: Color

    public init(_ text: String, color: Color = Tokens.textDim) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(TypeScale.font(TypeScale.caption, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(color)
    }
}

/// The chevron that means "this opens or expands". One glyph, one rotation, one easing.
public struct DisclosureGlyph: View {
    private let expanded: Bool
    private let size: CGFloat

    public init(expanded: Bool, size: CGFloat = 9) {
        self.expanded = expanded
        self.size = size
    }

    public var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Tokens.textDim)
            .rotationEffect(.degrees(expanded ? 180 : 0))
            .accessibilityHidden(true)
    }
}

// MARK: - Grouped lists

/// One grouped card of rows: 16 pt corners on the grouped surface, optional caption and
/// footer. The iOS settings look, without a `Form` (which would take over scrolling,
/// background and typography).
public struct GroupedSection<Content: View>: View {
    private let caption: String?
    private let footer: String?
    private let content: Content

    public init(_ caption: String? = nil,
                footer: String? = nil,
                @ViewBuilder content: () -> Content) {
        self.caption = caption
        self.footer = footer
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let caption {
                Text(caption)
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textGroupedSecondary)
                    .padding(.horizontal, 4)
            }

            VStack(spacing: 0) { content }
                .groupedSurface()

            if let footer {
                Text(footer)
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textGroupedSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// One row of a grouped card. The separator is drawn by the row so its inset can follow
/// the icon; the last row in a group passes `showsSeparator: false`.
public struct GroupedListRow<Accessory: View>: View {
    private let title: String
    private let subtitle: String?
    private let detail: String?
    private let systemImage: String?
    private let iconTint: Color
    private let showsChevron: Bool
    private let showsSeparator: Bool
    private let isDestructive: Bool
    private let accessory: Accessory

    #if os(iOS)
    private let rowHeight: CGFloat = 44
    #else
    private let rowHeight: CGFloat = 38
    #endif

    public init(_ title: String,
                subtitle: String? = nil,
                detail: String? = nil,
                systemImage: String? = nil,
                iconTint: Color = Tokens.textMuted,
                showsChevron: Bool = false,
                showsSeparator: Bool = true,
                isDestructive: Bool = false,
                @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.systemImage = systemImage
        self.iconTint = iconTint
        self.showsChevron = showsChevron
        self.showsSeparator = showsSeparator
        self.isDestructive = isDestructive
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(isDestructive ? Tokens.danger : iconTint)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                                .fill(Tokens.control)
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(isDestructive ? Tokens.danger : Tokens.textPrimary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(TypeScale.font(TypeScale.label))
                            .foregroundStyle(Tokens.textGroupedSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                if let detail {
                    Text(detail)
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.textGroupedSecondary)
                        .lineLimit(1)
                }

                accessory

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tokens.textDim)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: rowHeight)

            if showsSeparator {
                Hairline(color: Tokens.borderGrouped)
                    .padding(.leading, systemImage == nil ? 14 : 52)
            }
        }
        .contentShape(Rectangle())
    }
}

public extension GroupedListRow where Accessory == EmptyView {
    init(_ title: String,
         subtitle: String? = nil,
         detail: String? = nil,
         systemImage: String? = nil,
         iconTint: Color = Tokens.textMuted,
         showsChevron: Bool = false,
         showsSeparator: Bool = true,
         isDestructive: Bool = false) {
        self.init(title,
                  subtitle: subtitle,
                  detail: detail,
                  systemImage: systemImage,
                  iconTint: iconTint,
                  showsChevron: showsChevron,
                  showsSeparator: showsSeparator,
                  isDestructive: isDestructive,
                  accessory: { EmptyView() })
    }
}

// MARK: - Previews

#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#Preview("Hairline · caption · progress") {
    VStack(alignment: .leading, spacing: 18) {
        SectionCaption("CONTEXT")
        Hairline()
        IndeterminateProgressBar().frame(width: 200)
        HStack(spacing: 12) {
            SpinningRing()
            SpinningRing(color: Tokens.success, size: 14)
            DisclosureGlyph(expanded: true)
        }
    }
    .padding(20)
    .frame(width: 280)
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
#endif
#endif
#endif
#endif
#endif
#endif
#endif
#endif
#endif
#endif

#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#if DEBUG
#Preview("Grouped section") {
    GroupedSection("Host", footer: "Pairing arrives in M2.") {
        GroupedListRow("Hermes host", subtitle: "host.example.ts.net", detail: "Connected", systemImage: "bolt.fill", iconTint: Tokens.accentText, showsChevron: true)
        GroupedListRow("Protocol", detail: "v3", systemImage: "arrow.left.arrow.right")
        GroupedListRow("Revoke this device", systemImage: "trash", showsSeparator: false, isDestructive: true)
    }
    .padding(16)
    .frame(width: 360)
    .background(Tokens.sheet)
    .preferredColorScheme(.dark)
}
#endif
#endif
#endif
#endif
#endif
#endif
#endif
#endif
#endif
#endif

// MARK: - Cross-platform sheet chrome

/// Small modifiers that exist only to keep `#if os(iOS)` out of three modifier chains at once.

/// A sheet title is inline on the phone and has no such control on the Mac, so the modifier that
/// says so lives here instead of a `#if` inside three modifier chains.
struct InlineSheetTitle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationBarTitleDisplayMode(.inline)
        #else
        content
        #endif
    }
}

/// A bot name is lowercase on the host; the keyboard should not capitalise the first letter.
struct NoAutoCapitalisation: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.textInputAutocapitalization(.never)
        #else
        content
        #endif
    }
}

extension View {
    func inlineSheetTitle() -> some View { modifier(InlineSheetTitle()) }
    func noAutoCapitalisation() -> some View { modifier(NoAutoCapitalisation()) }
}

/// A sheet on the Mac sizes itself to its content, and a `List` has no intrinsic height — so a
/// navigation stack full of rows collapses to its title bar and the sheet looks empty. This is the
/// one place that gives those sheets a floor, instead of a `#if os(macOS)` in five files.
struct SheetSizing: ViewModifier {
    let minWidth: CGFloat
    let minHeight: CGFloat

    func body(content: Content) -> some View {
        #if os(macOS)
        content.frame(minWidth: minWidth, idealWidth: minWidth + 60,
                      minHeight: minHeight, idealHeight: minHeight + 120)
        #else
        content
        #endif
    }
}

extension View {
    func sheetSizing(minWidth: CGFloat = 440, minHeight: CGFloat = 480) -> some View {
        modifier(SheetSizing(minWidth: minWidth, minHeight: minHeight))
    }
}
