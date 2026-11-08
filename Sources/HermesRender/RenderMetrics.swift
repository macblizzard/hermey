import Foundation

/// The two apps, as far as typography is concerned.
public enum RenderPlatform: String, CaseIterable, Sendable {
    case macOS
    case iOS
}

/// Chat typography, in the block layer.
///
/// OpenBot draws chat text at **16 pt on a 22 pt line on iOS** and **14 pt/1.62 on
/// macOS** (`Sources/OpenBotUI/Tokens.swift`, mirroring upstream
/// `chat-text-styles.ts`). Those numbers used to be decided by whichever view
/// happened to draw the message; keeping them here means a transcript, a markdown
/// block, a diff and a tool-output window all agree.
///
/// Values are points and multiples, never colours or fonts — each platform turns
/// them into `Font`/`lineSpacing` itself.
public struct ChatTextMetrics: Equatable, Sendable {
    public let platform: RenderPlatform
    /// Body copy size in points: 16 on iOS, 14 on macOS.
    public let bodySize: CGFloat
    /// Absolute body line height in points: 22 on iOS, 14 × 1.62 = 22.68 on macOS.
    public let bodyLineHeight: CGFloat
    /// Monospace size for code, inline code and diffs (OpenBot `Tokens.mono`).
    public let codeSize: CGFloat
    /// Monospace line height; tool output and diffs are dense, 1.45 × size.
    public let codeLineHeight: CGFloat

    /// The CSS-style line-height multiple OpenBot's macOS table uses (1.62).
    public var bodyLineHeightMultiple: CGFloat { bodyLineHeight / bodySize }

    public init(
        platform: RenderPlatform,
        bodySize: CGFloat,
        bodyLineHeight: CGFloat,
        codeSize: CGFloat = 11.5
    ) {
        precondition(bodySize > 0, "body size must be positive")
        precondition(bodyLineHeight >= bodySize, "line height cannot be shorter than the type")
        precondition(codeSize > 0, "code size must be positive")
        self.platform = platform
        self.bodySize = bodySize
        self.bodyLineHeight = bodyLineHeight
        self.codeSize = codeSize
        self.codeLineHeight = (codeSize * 1.45).rounded()
    }

    /// 16 pt on a 22 pt line — OpenBot's iOS chat text.
    public static let iOS = ChatTextMetrics(platform: .iOS, bodySize: 16, bodyLineHeight: 22)
    /// 14 pt on a 1.62 line — OpenBot's macOS chat text (22.68 pt).
    public static let macOS = ChatTextMetrics(platform: .macOS, bodySize: 14, bodyLineHeight: 14 * 1.62)

    public static func forPlatform(_ platform: RenderPlatform) -> ChatTextMetrics {
        switch platform {
        case .iOS: return .iOS
        case .macOS: return .macOS
        }
    }

    // MARK: Block sizes
    //
    // Headings scale off body copy so the ramp is identical in both apps; the
    // h5/h6 values flatten because OpenBot never draws chat headings smaller than
    // body copy (they are distinguished by weight and colour instead).
    static let headingScale: [CGFloat] = [1.5, 1.32, 1.18, 1.08, 1.0, 1.0]

    public static func headingScale(forLevel level: Int) -> CGFloat {
        let index = min(max(level, 1), 6) - 1
        return headingScale[index]
    }

    /// Point size for a whole block.
    public func fontSize(for block: Block) -> CGFloat {
        switch block {
        case .heading(let level, _):
            return (bodySize * ChatTextMetrics.headingScale(forLevel: level)).rounded()
        case .code:
            return codeSize
        default:
            return bodySize
        }
    }

    /// Line height for a whole block. Headings keep body leading proportional to
    /// their size; code uses the dense monospace leading.
    public func lineHeight(for block: Block) -> CGFloat {
        switch block {
        case .code:
            return codeLineHeight
        case .heading(let level, _):
            let size = bodySize * ChatTextMetrics.headingScale(forLevel: level)
            return (size * (bodyLineHeight / bodySize)).rounded()
        default:
            return bodyLineHeight
        }
    }

    /// Extra leading SwiftUI's `lineSpacing` has to add to reach `bodyLineHeight`.
    /// SF at 16 pt lays out at ≈19.09 pt, but the exact value is font-dependent, so
    /// this is an estimate the view may override.
    public var estimatedLineSpacing: CGFloat {
        max(0, bodyLineHeight - (bodySize * 1.2))
    }
}
