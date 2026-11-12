import SwiftUI
import HermesKit

/// A pill of state: transport, model, reasoning, a queue count.
///
/// One chip with a tone, not a chip per concept — that is how the palette stays at one
/// accent and three status colours. The dot and the text always agree, and the text is
/// there because colour alone is not a state (see the colour-blind rule in the spec).
public struct StatusChip: View {
    public enum Tone {
        case neutral
        case accent
        case success
        case warning
        case danger

        var ink: Color {
            switch self {
            case .neutral: return Tokens.textMuted
            case .accent: return Tokens.accentText
            case .success: return Tokens.success
            case .warning: return Tokens.warning
            case .danger: return Tokens.danger
            }
        }

        var fill: Color {
            switch self {
            case .neutral: return Tokens.control
            case .accent: return Tokens.accentSoft
            case .success: return Tokens.successSoft
            case .warning: return Tokens.warningSoft
            case .danger: return Tokens.dangerSoft
            }
        }

        var border: Color {
            switch self {
            case .neutral: return Tokens.borderStrong
            default: return .clear
            }
        }
    }

    public enum Size {
        case small
        case regular

        var points: CGFloat {
            switch self {
            case .small: return TypeScale.caption
            case .regular: return TypeScale.label
            }
        }
    }

    /// The path the connection takes. Tailscale gives either a direct route or a DERP
    /// relay; the chip says which, because the two have very different latency.
    public enum TransportPath {
        case direct
        case relay

        var label: String {
            switch self {
            case .direct: return "direct"
            case .relay: return "relay"
            }
        }
    }

    private let text: String
    private let tone: Tone
    private let systemImage: String?
    private let showsDot: Bool
    private let showsProgress: Bool
    private let size: Size

    public init(_ text: String,
                tone: Tone = .neutral,
                systemImage: String? = nil,
                showsDot: Bool = false,
                showsProgress: Bool = false,
                size: Size = .regular) {
        self.text = text
        self.tone = tone
        self.systemImage = systemImage
        self.showsDot = showsDot
        self.showsProgress = showsProgress
        self.size = size
    }

    public var body: some View {
        HStack(spacing: 5) {
            // Work in progress, said by a spinner: "compacting…" next to a still dot reads as a
            // status word that never updates, which is exactly how a 74-second compaction was
            // reported as a dead button.
            if showsProgress {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: size.points, height: size.points)
            }
            if showsDot {
                Circle()
                    .fill(tone.ink)
                    .frame(width: 5, height: 5)
            }
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size.points - 0.5, weight: .semibold))
            }
            Text(text)
                .font(TypeScale.font(size.points, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tone.ink)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(tone.fill))
        .overlay(Capsule().strokeBorder(tone.border, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    // MARK: - Factories

    /// The live connection chip: `direct · 31 ms`, `reconnecting`, `offline`.
    public static func transport(_ state: TransportState,
                                 path: TransportPath = .direct,
                                 rttMS: Int? = nil) -> StatusChip {
        switch state {
        case .open:
            let suffix = rttMS.map { " · \(max(0, $0)) ms" } ?? ""
            return StatusChip(path.label + suffix, tone: .success, showsDot: true)
        case .connecting:
            return StatusChip("connecting", tone: .warning, showsDot: true)
        case .reconnecting(let attempt):
            return StatusChip(attempt > 1 ? "reconnecting \(attempt)" : "reconnecting",
                              tone: .warning,
                              showsDot: true)
        case .closed(_), .failed(_):
            return StatusChip("offline", tone: .danger, showsDot: true)
        case .idle:
            return StatusChip("idle", tone: .neutral, showsDot: true)
        }
    }

    /// `model · grok-4` style: neutral, no dot, the value at label size.
    public static func model(_ label: String) -> StatusChip {
        StatusChip(label, tone: .neutral)
    }

    /// A reasoning-effort chip. Same neutral treatment; the label carries the meaning.
    public static func reasoning(_ label: String) -> StatusChip {
        StatusChip(label, tone: .neutral)
    }

    /// A count of queued turns. Warning, because a queue means the turn is waiting.
    public static func queued(_ count: Int) -> StatusChip {
        StatusChip(count == 1 ? "1 queued" : "\(count) queued",
                   tone: .warning,
                   systemImage: "clock",
                   size: .small)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Status chips") {
    VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
            StatusChip.transport(.open, path: .direct, rttMS: 31)
            StatusChip.transport(.reconnecting(attempt: 2))
            StatusChip.transport(.closed(reason: "host unreachable"))
            StatusChip.transport(.idle)
        }
        HStack(spacing: 8) {
            StatusChip.model("grok-4.1")
            StatusChip.reasoning("high")
            StatusChip.queued(3)
        }
        HStack(spacing: 8) {
            StatusChip("running", tone: .success, showsDot: true, size: .small)
            StatusChip("needs you", tone: .warning, showsDot: true, size: .small)
            StatusChip("failed", tone: .danger, size: .small)
            StatusChip("skill", tone: .accent, size: .small)
        }
    }
    .padding(20)
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
#endif
