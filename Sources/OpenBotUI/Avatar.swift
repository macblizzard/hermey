import SwiftUI

/// The session/agent avatar: initials, a presence state, and nothing else.
///
/// Presence is the only thing this draws in colour. `running` carries motion *and* a
/// ring, `needs you` carries a dot *and* is announced in the label, so neither state is
/// conveyed by hue alone. The fill is one of two token pairs (neutral or accent); the
/// choice is stable for a given name, so a session keeps the same face between launches
/// — `hashValue` is seeded per process and must never be used for this.
public struct Avatar: View {
    public enum Presence: Equatable {
        case idle
        case running
        case needsYou
    }

    public enum Size {
        /// 26 pt — the macOS session row.
        case small
        /// 34 pt — a conversation header.
        case medium
        /// 44 pt — the iOS session row.
        case large
        /// 64 pt — an empty state or a profile.
        case hero

        var side: CGFloat {
            switch self {
            case .small: return 26
            case .medium: return 34
            case .large: return 44
            case .hero: return 64
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .small: return 10
            case .medium: return 12
            case .large: return 15
            case .hero: return 21
            }
        }

        var dot: CGFloat {
            switch self {
            case .small, .medium: return 8
            case .large: return 10
            case .hero: return 13
            }
        }

        var ringWidth: CGFloat {
            switch self {
            case .small, .medium: return 1.5
            case .large, .hero: return 2
            }
        }
    }

    public enum Tone {
        case neutral
        case accent

        var fill: Color {
            switch self {
            case .neutral: return Tokens.surfaceRaised
            case .accent: return Tokens.accentSoft
            }
        }

        var ink: Color {
            switch self {
            case .neutral: return Tokens.textSecondary
            case .accent: return Tokens.accentText
            }
        }
    }

    private let name: String
    private let initials: String?
    private let image: Image?
    private let size: Size
    private let presence: Presence
    private let tone: Tone

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    public init(_ name: String,
                size: Size = .small,
                presence: Presence = .idle,
                tone: Tone? = nil,
                image: Image? = nil,
                initials: String? = nil) {
        self.name = name
        self.size = size
        self.presence = presence
        self.tone = tone ?? Avatar.tone(for: name)
        self.image = image
        self.initials = initials
    }

    public var body: some View {
        ZStack {
            Circle().fill(tone.fill)

            if let image {
                image
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Text(initials ?? Avatar.initials(for: name))
                    .font(TypeScale.font(size.fontSize, weight: .semibold))
                    .foregroundStyle(tone.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: size.side, height: size.side)
        .overlay(Circle().strokeBorder(Tokens.borderStrong, lineWidth: 1))
        .overlay(alignment: .center) { runningRing }
        .overlay(alignment: .bottomTrailing) { presenceDot }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var runningRing: some View {
        if presence == .running {
            Circle()
                .trim(from: 0, to: 0.24)
                .stroke(Tokens.accent, style: StrokeStyle(lineWidth: size.ringWidth, lineCap: .round))
                .padding(-2.5)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .opacity(reduceMotion ? 0.6 : 1)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                        spin = true
                    }
                }
        }
    }

    @ViewBuilder
    private var presenceDot: some View {
        if presence == .needsYou {
            Circle()
                .fill(Tokens.warning)
                .frame(width: size.dot, height: size.dot)
                .overlay(
                    Circle()
                        .strokeBorder(Tokens.canvas, lineWidth: 2)
                        .padding(-1)
                )
        }
    }

    private var accessibilityText: String {
        switch presence {
        case .idle: return name
        case .running: return "\(name), running"
        case .needsYou: return "\(name), needs you"
        }
    }

    // MARK: Derivation

    static func initials(for name: String) -> String {
        let words = name
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." })
            .prefix(2)
            .compactMap(\.first)
        let text = String(words).uppercased()
        return text.isEmpty ? "?" : text
    }

    /// Deterministic, process-independent: a sum of scalar values, not `hashValue`.
    static func tone(for name: String) -> Tone {
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return sum % 2 == 0 ? .neutral : .accent
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Avatar · presence") {
    VStack(spacing: 16) {
        HStack(spacing: 14) {
            Avatar("Hermes", size: .small, presence: .idle)
            Avatar("assistant", size: .medium, presence: .running)
            Avatar("Nightly build", size: .large, presence: .needsYou)
            Avatar("Research", size: .hero, presence: .running)
        }
        HStack(spacing: 14) {
            Avatar("Ops", size: .small, tone: .accent)
            Avatar("", size: .small)
            Avatar("x", size: .small, tone: .neutral)
        }
    }
    .padding(24)
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
#endif
