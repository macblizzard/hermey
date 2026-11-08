import ImageIO
import OpenBotUI
import SwiftUI
import UIKit

/// A small square preview of an image the user has attached but not sent yet.
///
/// The bytes in `PendingAttachment` are the *full* encoded upload, so decoding them at view
/// size keeps a 12-megapixel photo from becoming a 48 MB bitmap in the composer. `ImageIO`'s
/// thumbnail path reads only what it needs and never allocates the full image; the work runs
/// off the main actor because a HEIC decode is long enough to drop frames while scrolling.
struct AttachmentThumbnail: View {
    let data: Data
    let size: CGFloat

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                // Placeholder until the decode lands, and the permanent look for an image the
                // decoder could not read (a corrupt file still attaches as raw bytes).
                Image(systemName: "photo")
                    .font(.system(size: max(9, size * 0.42)))
                    .foregroundStyle(Tokens.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .background(Tokens.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Tokens.border, lineWidth: 0.5)
        }
        .accessibilityHidden(true)
        .task(id: data.count) {
            guard image == nil else { return }
            let bytes = data
            let pixels = Int(size * 3) // 3× so the preview stays sharp on the widest display
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.downsample(bytes, maxPixelSize: pixels)
            }.value
            if let decoded { image = decoded }
        }
    }

    private static func downsample(_ data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Orientation from EXIF, so a portrait shot is not shown on its side.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: thumbnail)
    }
}
