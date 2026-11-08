import SwiftUI
import OpenBotUI

/// The paperclip's menu.
///
/// A small card that floats just above the button the user tapped — the same shape as
/// iMessage's + menu, and deliberately *not* a `.confirmationDialog` or a page. The system
/// action sheet rendered at the bottom of the screen (or as a half sheet on iPad), which is
/// both the wrong place and the wrong size for a three-item choice, and presenting it also
/// raced the pickers it launched: the picker was asked to present while its presenter was
/// still dismissing, so the completion handler could be torn down before the user's choice
/// came back. An in-place overlay has no presentation to race.
struct AttachmentMenu: View {
    let onPick: (AttachmentSource) -> Void

    static let rowHeight: CGFloat = 42
    static let width: CGFloat = 208
    /// Used by the composer to place the card; kept next to the size it describes.
    static var height: CGFloat { rowHeight * CGFloat(AttachmentSource.allCases.count) }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(AttachmentSource.allCases.enumerated()), id: \.element.id) { index, source in
                if index > 0 {
                    Hairline(color: Tokens.border)
                        .padding(.leading, 40)
                }
                Button {
                    onPick(source)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: source.systemImage)
                            .font(.system(size: 15, weight: .regular))
                            .frame(width: 22)
                            .foregroundStyle(Tokens.textPrimary)
                        Text(source.title)
                            .font(TypeScale.font(TypeScale.sm))
                            .foregroundStyle(Tokens.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: Self.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add attachment")
    }
}
