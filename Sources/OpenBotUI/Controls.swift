import SwiftUI

// MARK: - Buttons

/// The only button in the kit.
///
/// Four kinds (the design system has one accent, so `primary` is blue and everything
/// else is neutral), two sizes, and a hit target that is 44 pt on the phone — the
/// approval buttons must never be smaller than that. Disabled is an explicit parameter
/// rather than an environment read: a `ButtonStyle` does not see `\.isEnabled`
/// reliably, and a button that looks enabled but is not is worse than no button.
public struct OpenBotButton: View {
    public enum Kind: Equatable {
        case primary
        case secondary
        case ghost
        case danger
    }

    public enum Size: Equatable {
        case small
        case regular
    }

    public enum Corners: Equatable {
        case rounded
        case capsule
    }

    private let title: String
    private let systemImage: String?
    private let kind: Kind
    private let size: Size
    private let corners: Corners
    private let isDisabled: Bool
    private let isBusy: Bool
    private let action: () -> Void

    public init(_ title: String,
                systemImage: String? = nil,
                kind: Kind = .secondary,
                size: Size = .regular,
                corners: Corners = .rounded,
                isDisabled: Bool = false,
                isBusy: Bool = false,
                action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.size = size
        self.corners = corners
        self.isDisabled = isDisabled
        self.isBusy = isBusy
        self.action = action
    }

    #if os(iOS)
    private var height: CGFloat { size == .regular ? 44 : 34 }
    private var fontSize: CGFloat { size == .regular ? TypeScale.xl - 1 : TypeScale.md }
    private var glyphSize: CGFloat { size == .regular ? 13 : 11 }
    private var horizontalPadding: CGFloat { size == .regular ? 16 : 11 }
    #else
    private var height: CGFloat { size == .regular ? 30 : 24 }
    private var fontSize: CGFloat { size == .regular ? 12 : 11 }
    private var glyphSize: CGFloat { size == .regular ? 10.5 : 9.5 }
    private var horizontalPadding: CGFloat { size == .regular ? 13 : 9 }
    #endif

    private var radius: CGFloat {
        corners == .capsule ? height / 2 : Tokens.radiusControl
    }

    private var fill: Color {
        switch kind {
        case .primary: return Tokens.accent
        case .secondary: return Tokens.control
        case .ghost: return .clear
        case .danger: return Tokens.dangerSoft
        }
    }

    private var hoverColor: Color {
        switch kind {
        case .primary: return Tokens.accentHover
        case .secondary, .ghost: return Tokens.controlHover
        case .danger: return Tokens.dangerSoft
        }
    }

    private var foreground: Color {
        switch kind {
        // --openbot-text-on-accent is #ffffff, which is text-primary in the dark palette.
        case .primary: return Tokens.textPrimary
        case .secondary: return Tokens.textSecondary
        case .ghost: return Tokens.textMuted
        case .danger: return Tokens.danger
        }
    }

    private var border: Color {
        kind == .secondary ? Tokens.borderStrong : .clear
    }

    public var body: some View {
        Button {
            guard !isDisabled, !isBusy else { return }
            action()
        } label: {
            HStack(spacing: 6) {
                if isBusy {
                    SpinningRing(color: foreground, size: glyphSize + 2, lineWidth: 1.5)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: glyphSize, weight: .semibold))
                }
                Text(title)
                    .font(TypeScale.font(fontSize, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .hoverFill(rest: fill, hover: hoverColor, radius: radius)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .accessibilityLabel(title)
    }
}

/// Icon-only button for a toolbar or a card corner. `label` is required: an icon has no
/// accessible name of its own.
public struct OpenBotIconButton: View {
    private let systemImage: String
    private let label: String
    private let size: OpenBotButton.Size
    private let isDisabled: Bool
    private let isBusy: Bool
    private let action: () -> Void

    public init(_ systemImage: String,
                label: String,
                size: OpenBotButton.Size = .regular,
                isDisabled: Bool = false,
                isBusy: Bool = false,
                action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.size = size
        self.isDisabled = isDisabled
        self.isBusy = isBusy
        self.action = action
    }

    #if os(iOS)
    private var side: CGFloat { size == .regular ? 44 : 34 }
    private var glyphSize: CGFloat { size == .regular ? 15 : 12 }
    #else
    private var side: CGFloat { size == .regular ? 28 : 24 }
    private var glyphSize: CGFloat { size == .regular ? 12.5 : 11 }
    #endif

    public var body: some View {
        Button {
            guard !isDisabled, !isBusy else { return }
            action()
        } label: {
            Group {
                if isBusy {
                    SpinningRing(color: Tokens.textMuted, size: glyphSize - 2, lineWidth: 1.5)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: glyphSize, weight: .regular))
                }
            }
            .foregroundStyle(Tokens.textMuted)
            .frame(width: side, height: side)
            .hoverFill(rest: .clear, hover: Tokens.controlHover, radius: Tokens.radiusControl)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        // No focus ring: at launch the first focusable control in the window is this glyph row,
        // and macOS drew its blue ring around the search icon before the pointer had moved. The
        // ring is not information here — the hover fill is — and every one of these verbs has a
        // menu shortcut besides.
        .focusable(false)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .accessibilityLabel(label)
        // Every glyph is a question until it is hovered; the label was already written for
        // VoiceOver, so the tooltip costs nothing and answers the same question.
        #if os(macOS)
        .help(label)
        #endif
    }
}

/// An inline text action ("Retry", "Show all"). 11 pt, semibold, no fill — for the place
/// where a bordered button would be too heavy.
public struct TextButton: View {
    private let title: String
    private let tone: Color
    private let isDisabled: Bool
    private let action: () -> Void

    public init(_ title: String,
                tone: Color = Tokens.accentText,
                isDisabled: Bool = false,
                action: @escaping () -> Void) {
        self.title = title
        self.tone = tone
        self.isDisabled = isDisabled
        self.action = action
    }

    public var body: some View {
        Button {
            guard !isDisabled else { return }
            action()
        } label: {
            Text(title)
                .font(TypeScale.font(TypeScale.label, weight: .semibold))
                .foregroundStyle(isDisabled ? Tokens.textDim : tone)
                // 6 pt above and below an 11 pt line clears the 24 pt minimum hit target.
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(title)
    }
}

/// Press feedback shared by every control: a small dim and a 0.985 scale. No colour
/// change, so a pressed ghost button does not invent a shade the tokens do not have.
public struct PressableButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

// MARK: - Previews

#if DEBUG
#if DEBUG
#if DEBUG
#Preview("Buttons · dark") {
    VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 8) {
            OpenBotButton("Allow once", kind: .primary) {}
            OpenBotButton("Always for this session", kind: .ghost) {}
            OpenBotButton("Deny", kind: .danger) {}
        }
        HStack(spacing: 8) {
            OpenBotButton("Send", systemImage: "arrow.up", kind: .primary, size: .small) {}
            OpenBotButton("Retry", kind: .secondary, size: .small) {}
            OpenBotButton("Sending", kind: .secondary, size: .small, isBusy: true) {}
            OpenBotButton("Disabled", kind: .primary, size: .small, isDisabled: true) {}
        }
        HStack(spacing: 8) {
            OpenBotButton("Continue", kind: .primary, corners: .capsule) {}
            OpenBotIconButton("paperclip", label: "Attach a file") {}
            OpenBotIconButton("mic", label: "Dictate") {}
            TextButton("Retry") {}
        }
    }
    .padding(24)
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
#endif
#endif
#endif
