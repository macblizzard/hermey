import SwiftUI

/// The bot list's sizes, as one number the owner can drag.
///
/// Every value a row draws with — the face, the name, the preview line, the row's own height and
/// spacing — is derived from `Geometry`/`TypeScale` and then multiplied by this scale. That is the
/// whole point: one slider moves the row as a unit, so nothing can drift out of step with the face
/// beside it.
///
/// The default (1.0) reproduces the size the list shipped with, so a person who never opens
/// Appearance sees exactly what they saw before. Dynamic Type still applies on top: this scales the
/// *base*, it does not replace the system's own size.
public struct BotListMetrics: Equatable {
    /// 1.0 is the shipped size. Below it the row shrinks, above it grows.
    public static let defaultScale: Double = 1
    /// Clamped so neither end can produce a row that is unusable: 0.85 still reads, 1.35 still
    /// fits a phone's width with a two-line name.
    public static let minScale: Double = 0.85
    public static let maxScale: Double = 1.35
    /// The key the choice is stored under, on both apps.
    public static let storageKey = "hermey.botListScale"

    public let scale: Double

    public init(scale: Double) {
        guard scale.isFinite else { self.scale = Self.defaultScale; return }
        self.scale = min(max(scale, Self.minScale), Self.maxScale)
    }

    private func scaled(_ value: CGFloat) -> CGFloat { (value * CGFloat(scale)).rounded() }

    public var avatar: CGFloat { scaled(Geometry.rosterAvatar) }
    /// The face on a search finding: a step smaller than a row's, so the snippet keeps its width.
    public var avatarCompact: CGFloat { scaled(Geometry.rosterAvatarCompact) }
    public var rowHeight: CGFloat { scaled(Geometry.rosterRow) }
    public var rowPadding: CGFloat { scaled(Geometry.rosterRowPadding) }
    public var gap: CGFloat { scaled(Geometry.rosterRowGap) }
    /// The count badge rides on the face, so it scales with it.
    public var badge: CGFloat { scaled(19) }
    public var nameSize: CGFloat { scaled(TypeScale.sessionTitle) }
    public var previewSize: CGFloat { scaled(TypeScale.sessionPreview) }
    public var metaSize: CGFloat { scaled(Tokens.rosterMeta) }
}

/// The sample row under the size slider: the list's own face, name and preview line, drawn at the
/// size being chosen — so the choice is visible before Settings is closed.
public struct BotListScalePreview: View {
    private let metrics: BotListMetrics

    public init(scale: Double) {
        self.metrics = BotListMetrics(scale: scale)
    }

    public var body: some View {
        HStack(spacing: metrics.gap) {
            BotAvatarView(identity: "preview", size: metrics.avatar, animates: false)
            VStack(alignment: .leading, spacing: 2) {
                Text("Aria")
                    .font(TypeScale.font(metrics.nameSize, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                Text("Sample bot row")
                    .font(TypeScale.font(metrics.previewSize))
                    .foregroundStyle(Tokens.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, metrics.rowPadding)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
            .fill(Tokens.surface))
    }
}
