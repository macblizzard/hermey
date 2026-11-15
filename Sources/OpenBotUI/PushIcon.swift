import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The face a banner carries.
///
/// Bark shows one image inside a notification and takes a URL. The image has to be the *actual*
/// roster face — `BotSilhouette` is SwiftUI geometry, and a second drawing of it in another language
/// would drift the first time a shape is touched. So the app renders the portrait it already draws,
/// on the plate the app icon uses, and hands the bytes to the host.
///
/// The plate is baked in rather than leaving the face on transparency: a notification shows the image
/// over whatever wallpaper the phone has, and a warm face on nothing disappears on a warm wallpaper.
public enum PushIcon {

    /// Side of the rendered image. Bark scales it into a thumbnail; this only has to be sharp.
    public static let size: CGFloat = 128

    @MainActor
    public static func png(for face: BotFace) -> Data? {
        let plate = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
            .fill(LinearGradient(colors: [Tokens.surfaceRaised, Tokens.background],
                                 startPoint: .top, endPoint: .bottom))
        let portrait = BotIconPortrait(face, size: size * 0.76)
            .frame(width: size, height: size)
            .background(plate)
        let renderer = ImageRenderer(content: portrait)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        #if os(iOS)
        return UIImage(cgImage: image).pngData()
        #else
        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(using: .png, properties: [:])
        #endif
    }
}
