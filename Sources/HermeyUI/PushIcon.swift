import HermesKit
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The face a banner carries.
///
/// Bark shows one image inside a notification and takes a URL. The image has to be the *actual*
/// face the roster draws, and there are two of those: a bot with a generated avatar wears its drawn
/// definition, and a bot without one wears the shipped shape in its palette colour. This type is the
/// one place the choice is made for a banner, so no cache and no upload path can disagree with the
/// roster about which face a bot has.
///
/// **The drawn avatar goes first.** `BotAvatarIcon` renders the definition at rest, in the stored
/// colour and material, into the bytes below. A bot that saved a definition therefore never shows
/// the shape it used to wear — on a banner, in the notification list, or on the icon the host serves
/// to a relay (the host stores what this function uploaded; it draws nothing itself).
///
/// **A bot without a definition is unchanged.** It takes `shapePNG`, which is exactly the picture
/// that shipped before definitions existed: `BotAvatarStill` on the app-icon plate. And when a
/// definition cannot be drawn, that same shape face is the fallback — a banner with the old face is
/// better than a banner with a blank square.
///
/// The plate is baked in rather than leaving the face on transparency: a notification shows the image
/// over whatever wallpaper the phone has, and a warm face on nothing disappears on a warm wallpaper.
public enum PushIcon {

    /// Side of the rendered image. Bark scales it into a thumbnail; this only has to be sharp.
    public static let size: CGFloat = 128

    /// The picture for one bot, drawn avatar first.
    ///
    /// - Parameters:
    ///   - botID: the bot, for the drawn renderer's cache key and for logging.
    ///   - avatar: the host's stored document, or nil for a bot with no definition. The stored
    ///     colour and material travel with it; `color` is deliberately ignored when this is non-nil,
    ///     because a stale `bots.color` must not repaint a newer face.
    ///   - color: the stored `#RRGGBB::shape_N`, used only by the shape face.
    @MainActor
    public static func png(for botID: String,
                           avatar: BotAvatarDocument?,
                           color: String? = nil) -> Data? {
        if let avatar {
            if let drawn = BotAvatarIcon.png(for: botID, avatar: avatar, size: size) {
                return drawn
            }
            // `BotAvatarIcon` already logged why. The shape face is the honest fallback: the bot has
            // a definition, but nothing drawable reached a bitmap.
            ClientLog.note("push icon: \(botID) has a definition that did not render; using the shape face",
                           level: .warning, category: "notifications")
        }
        return shapePNG(for: botID, color: color)
    }

    /// The face that shipped before generated avatars: `BotAvatarStill` on the plate.
    ///
    /// Internal so the fallback is one function, not a copy: `png(for:avatar:color:)` is its only
    /// caller, and a bot with no definition must keep exactly this picture.
    @MainActor
    static func shapePNG(for botID: String, color: String?) -> Data? {
        let plate = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
            .fill(LinearGradient(colors: [Tokens.surfaceRaised, Tokens.surface],
                                 startPoint: .top, endPoint: .bottom))
        // `BotAvatarStill`, not `BotAvatarView`: the animated view draws inside a `TimelineView`,
        // which `ImageRenderer` cannot sample — the render came back blank and every banner lost
        // its face. This is the same body and bars with no timeline to sample.
        let portrait = BotAvatarStill(identity: botID,
                                      color: color,
                                      size: size * 0.76)
            .frame(width: size, height: size)
            .background(plate)
        let renderer = ImageRenderer(content: portrait)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            ClientLog.note("push icon: the shape face for \(botID) rendered no image",
                           level: .warning, category: "notifications")
            return nil
        }
        #if os(iOS)
        return UIImage(cgImage: image).pngData()
        #else
        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(using: NSBitmapImageRep.FileType.png,
                                             properties: [NSBitmapImageRep.PropertyKey: Any]())
        #endif
    }

    /// Forget a bot's rendered bytes after its avatar or face changed.
    public static func invalidate(botID: String) {
        BotAvatarIcon.invalidate(botID: botID)
    }

    /// Forget every rendered face: unpairing or switching hosts.
    public static func invalidateAll() {
        BotAvatarIcon.invalidateAll()
    }
}
