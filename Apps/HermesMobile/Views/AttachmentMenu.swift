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

    /// The shape the reference uses: a panel rather than a list, tall rows with the icon in one
    /// left column, no rules between them — the spacing is the separator. A hairline between three
    /// generous rows is a line drawn across a menu that already reads as three things.
    static let rowHeight: CGFloat = 56
    static let width: CGFloat = 252
    static let corner: CGFloat = 24
    /// Used by the composer to place the card; kept next to the size it describes.
    static var height: CGFloat { rowHeight * CGFloat(AttachmentSource.menuOrder.count) + 20 }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(AttachmentSource.menuOrder) { source in
                Button {
                    onPick(source)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: source.systemImage)
                            .font(.system(size: 18, weight: .regular))
                            .frame(width: 24)
                            .foregroundStyle(Tokens.textPrimary)
                        Text(source.title)
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(Tokens.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .frame(height: Self.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .frame(width: Self.width)
        .hermeyGlass(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .shadow(color: .black.opacity(0.30), radius: 22, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add attachment")
    }
}
