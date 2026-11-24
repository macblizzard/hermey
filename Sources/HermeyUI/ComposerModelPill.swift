import Foundation
import SwiftUI

/// What the composer's chrome says about the session: `provider/model`, and how full its context is.
///
/// **One rendering for two apps.** The owner photographed a line reading
/// `Opencode-Go/Deepseek-v4.1-flash   |   540k/1M Tokens` over the compose box and asked for it on
/// both apps, tastefully. The phone already owned one half of the rule — `TokenCount`, the same
/// `540k` / `1M` the header prints — and the Mac owned none of it, so the two would have drifted the
/// moment either was edited. Both now print through these two functions.
public enum SessionLine {
    /// `opencode-go/deepseek-v4.1-flash`.
    ///
    /// The host's catalogue names the running model (`deepseek-v4.1-flash`) and its provider
    /// (`opencode-go`) as two fields, and a name that already carries a slash is left alone rather
    /// than prefixed twice. An empty provider is not invented: the model is printed on its own.
    public static func model(provider: String?, model: String?) -> String? {
        let name = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard !name.contains("/") else { return name }
        let slug = (provider ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { return name }
        return "\(slug)/\(name)"
    }

    /// `540k/1M Tokens` — `TokenCount`'s rule, so the composer and the header cannot disagree.
    ///
    /// Both halves come from the host: `used` from the last completed turn's `usage`, `limit` from
    /// the window it reported. With a window, both are printed; with only `used`, the count is
    /// printed without a limit rather than against a guessed one; with neither, there is no line at
    /// all — a made-up `1M` is exactly the kind of number a reader would trust.
    public static func context(used: Int?, limit: Int?) -> String? {
        guard let used, used >= 0 else { return nil }
        guard let limit, limit > 0 else { return "\(TokenCount.short(used)) Tokens" }
        return "\(TokenCount.short(used))/\(TokenCount.short(limit)) Tokens"
    }
}

/// The session's model — and the door to its picker — as a pill in the composer's own control row.
///
/// It began as a line *over* the capsule. Mohammad's sample (2026-11-24) put it where it belongs:
/// **inside** the composer, in the same row as the paperclip and the send arrow, immediately right
/// of the attach control — a dark rounded pill with a small tinted round glyph, the model in
/// semibold, the context count quieter beside it, and a chevron. That makes it part of the control
/// rather than text sitting near it, and the field above keeps its own height and padding exactly:
/// the pill is a *sibling* in the row, never an overlay over the text.
///
/// Four rules survive from the line, because they are what kept it out of the reader's way:
///
/// * **it never wraps or grows.** One line; `ViewThatFits` drops the token count on a narrow window
///   and keeps the model name and the chevron, because the model is the half that identifies the
///   conversation. The name itself truncates at the tail rather than widening the row.
/// * **it cannot repaint while typing.** It reads four values and nothing else — no draft, no
///   geometry — and it is `Equatable` (the action closure is excluded: the four values already
///   identify what is drawn), so `Composer` applies `.equatable()` and a keystroke that changes only
///   the field does not lay the pill out again.
/// * **the whole pill is one button.** The chevron is part of it, not a second control: the glyph,
///   the name, the count and the chevron all open the *existing* model picker for this bot, which
///   the caller supplies. There is no picker in here.
/// * **it is chrome, so it looks like chrome.** The app's own fill (`Tokens.control`), lightened
///   under the pointer on the Mac — and under keyboard focus, where the system would otherwise
///   draw its accent ring — with the shared press feedback (`PressableButtonStyle`) — no
///   underline, no accent text, no link affordance anywhere in it.
public struct ComposerModelPill: View, Equatable {
    private let provider: String?
    private let model: String?
    private let used: Int?
    private let limit: Int?
    private let isEnabled: Bool
    /// Opening the picker is the caller's business: the Mac opens the same sheet the bot panel's
    /// Model row does, the phone the same sheet its drawer does. This view knows none of that.
    private let onOpen: () -> Void

    /// Pointer hover, for the Mac. `@State` inside an `Equatable` view is still invalidated by the
    /// pointer — equality only decides whether the *caller's* re-render reaches this body.
    @State private var isHovered = false

    /// Keyboard focus. The pill is a tab stop, and the system's answer to a focused button is the
    /// accent ring, which this app never wears (`hermeyFocusQuiet()`); the pill's own answer is the
    /// same one step the pointer gets, so a keyboard user still sees where they are.
    @FocusState private var isFocused: Bool

    public init(provider: String?,
                model: String?,
                used: Int?,
                limit: Int?,
                isEnabled: Bool = true,
                onOpen: @escaping () -> Void) {
        self.provider = provider
        self.model = model
        self.used = used
        self.limit = limit
        self.isEnabled = isEnabled
        self.onOpen = onOpen
    }

    /// The four values that decide what is drawn. The closure is deliberately left out: it is
    /// rebuilt on every parent body pass, and comparing it would defeat `.equatable()` entirely.
    public static func == (lhs: ComposerModelPill, rhs: ComposerModelPill) -> Bool {
        lhs.provider == rhs.provider
            && lhs.model == rhs.model
            && lhs.used == rhs.used
            && lhs.limit == rhs.limit
            && lhs.isEnabled == rhs.isEnabled
    }

    /// The tinted round glyph's side. The pill's height is the row's own control height, given by
    /// `Composer`, so the lozenge is level with the paperclip and the send arrow.
    private var glyphSide: CGFloat { 16 }

    public var body: some View {
        let name = SessionLine.model(provider: provider, model: model)
        let tokens = SessionLine.context(used: used, limit: limit)

        // No model name, no pill: an empty dark lozenge would be a control that says nothing and
        // opens a picker for a bot whose model the host never named.
        if let name {
            Button(action: onOpen) {
                HStack(spacing: 5) {
                    glyph

                    // Both parts, always: the model gives up width first and truncates, the count
                    // keeps its room. The old fit-based fallback dropped the whole count on a narrow
                    // pill, which is why the phone lost it while the Mac kept it — the number is what
                    // the reader came for, so it is not the thing that disappears.
                    HStack(spacing: 4) {
                        modelName(name)
                            .layoutPriority(0)
                        if let tokens {
                            context(tokens)
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(1)
                        }
                    }

                    chevron
                }
                // About the sample's 14 pt, trimmed to 12 because this pill is the height of the
                // Mac's 26 pt row controls and a wider inset reads as a lozenge rather than a chip.
                .padding(.horizontal, 14)
                // Fills the row's control height. `fixedSize(vertical:)` used to sit below this and
                // pinned the lozenge to its text height, so it read as a slim bar beside round
                // buttons twice its height — the row's height is the pill's height.
                .frame(maxHeight: .infinity)
                .frame(minHeight: 0)
                // Dark lozenge, no border: the fill the bar composer already uses, one step lighter
                // under the pointer — and on keyboard focus, which is why focus needs no rim here
                // and gets none: a rim inside the field would read as a text field inside the field.
                .background(Capsule().fill(isEnabled && (isHovered || isFocused) ? Tokens.controlHover
                                                                                : Tokens.control))
                .contentShape(Capsule())
            }
            .buttonStyle(PressableButtonStyle())
            // Focus lands and draws the pill's own fill; the system's accent ring does not.
            .focused($isFocused)
            .onHoverCompat { isHovered = $0 }
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.55)
            .lineLimit(1)
            // One element to VoiceOver: glyph, name, count and chevron are a single control.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(name: name))
            .accessibilityHint("Opens this bot's model picker")
            .accessibilityAddTraits(.isButton)
            .hermeyFocusQuiet()
            #if os(macOS)
            .help("Model: \(name)")
            #endif
        }
    }

    private func modelName(_ name: String) -> some View {
        Text(name)
            .font(TypeScale.font(TypeScale.label, weight: .semibold))
            .foregroundStyle(Tokens.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// The count, quieter than the name and beside it — a gap, not a divider.
    private func context(_ tokens: String) -> some View {
        Text(tokens)
            .font(TypeScale.font(TypeScale.caption))
            .foregroundStyle(Tokens.textMuted)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// A small round tinted glyph, so the pill reads as the session's fact rather than a menu title.
    private var glyph: some View {
        ZStack {
            Circle().fill(Tokens.accentSoft)
            Image(systemName: "cpu")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Tokens.accentText)
        }
        .frame(width: glyphSide, height: glyphSide)
        .accessibilityHidden(true)
    }

    /// Part of the pill's one button, never a control of its own.
    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(Tokens.textDim)
            .accessibilityHidden(true)
    }

    private func accessibilityLabel(name: String) -> String {
        if let tokens = SessionLine.context(used: used, limit: limit) {
            return "Model \(name), \(tokens)"
        }
        return "Model \(name)"
    }
}
