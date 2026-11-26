import Foundation
import HermesKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A bot's **drawn** avatar, rasterised once for the surfaces that can only carry a picture.
///
/// A notification banner has no view hierarchy to draw into: iOS takes its corner icon from the app
/// bundle, and the only per-notification image is an attachment. So a bot's face has to become
/// bytes. Those bytes must be the drawn avatar — the same `OpenBotAvatarRenderer` the roster uses —
/// and not the old shape-and-palette face: a bot that saved a definition was still wearing its
/// previous face on a banner, in the notification list and on the icon the host serves to the relay.
///
/// This is the one function that makes those bytes. `PushIcon` asks it first and only falls back to
/// the shape face when the bot has no definition at all, or when a definition cannot be drawn (a
/// logged fallback is better than a blank banner).
///
/// **No motion, no clock.** The render is the rest pose at `t = 0` with `reducedMotion: true`, from a
/// model that is already built and cached (`OpenBotAvatarModel`). `ImageRenderer` cannot sample a
/// `TimelineView`, so the drawing goes through a plain `Canvas` — exactly the call
/// `OpenBotAvatarView` makes, evaluated once. The eye catchlight is the material plan's own rule (it
/// is not drawn below 64 pt), which is why the size is handed to the renderer rather than decided
/// here.
public enum BotAvatarIcon {

    /// The side a banner icon is rendered at. `PushIcon` has used 128 since the face moved into the
    /// notification; it is sharp at every banner size and cheap to redraw.
    public static let defaultSize: CGFloat = 128

    /// How much of the plate the face fills — the same 0.76 the shape face used, so a bot that
    /// switches to a drawn avatar does not change size inside the same banner.
    ///
    /// `fileprivate` because the still view below is a separate type in this file and reads it.
    fileprivate static let faceInset: CGFloat = 0.76

    // MARK: - Cache

    /// One render per bot, size, material, colour and body.
    ///
    /// The key carries the definition's own contents as well as the bot id, so an edit that did not
    /// go through a save (an editor preview, a host that pushed a new document) cannot reuse the old
    /// picture. Saving or clearing still invalidates explicitly — `invalidate(botID:)` — because a
    /// cache that only notices a difference in the body would miss a material change on the same
    /// body.
    private static let lock = NSLock()
    private static var cache: [String: Data] = [:]
    /// A phone has a few dozen bots; this is headroom, not a budget.
    private static let cacheLimit = 32

    // MARK: - Render

    /// Render one bot's drawn avatar on the banner plate.
    ///
    /// Returns nil when the definition cannot be drawn or the renderer answers no image; the caller
    /// logs that and draws the shape face instead. Rendering is main-actor work (`ImageRenderer`), and
    /// no notification path calls this: the face caches render at launch and on a save, and a banner
    /// only reads the file they wrote.
    @MainActor
    public static func png(for botID: String,
                           avatar: BotAvatarDocument,
                           size: CGFloat = BotAvatarIcon.defaultSize) -> Data? {
        let key = cacheKey(botID: botID, avatar: avatar, size: size)
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let hit { return hit }

        guard let model = OpenBotAvatarModel.model(for: avatar.definition) else {
            ClientLog.note("avatar icon: \(botID)'s definition cannot be drawn; using the shape face",
                           level: .warning, category: "notifications")
            return nil
        }

        let renderer = ImageRenderer(content: BotAvatarIconStill(model: model,
                                                                 definition: avatar.definition,
                                                                 color: avatar.color,
                                                                 material: avatar.material,
                                                                 size: size))
        // The same 2× the shape face has always rendered at: a banner thumbnail, not a wallpaper.
        renderer.scale = 2
        guard let image = renderer.cgImage, let data = encode(image) else {
            ClientLog.note("avatar icon: \(botID)'s face rendered no image; using the shape face",
                           level: .warning, category: "notifications")
            return nil
        }

        lock.lock()
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = data
        lock.unlock()
        return data
    }

    /// Forget one bot's rendered bytes. Called when its avatar is saved or cleared, so the next
    /// banner cannot be the face the bot no longer wears.
    public static func invalidate(botID: String) {
        lock.lock()
        let prefix = "\(botID)|"
        cache = cache.filter { !$0.key.hasPrefix(prefix) }
        lock.unlock()
    }

    /// Forget every rendered face — unpairing, a host switch, or a test that must start cold.
    public static func invalidateAll() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// What makes two renders the same: the bot, the body, the colour, the material and the size.
    static func cacheKey(botID: String, avatar: BotAvatarDocument, size: CGFloat) -> String {
        let eyes = avatar.definition.eyes
        return [
            botID,
            avatar.definition.id,
            avatar.definition.body.path,
            "\(eyes.x),\(eyes.y),\(eyes.spacing),\(eyes.scale)",
            avatar.color ?? "-",
            avatar.material.rawValue,
            String(Int(size.rounded())),
        ].joined(separator: "|")
    }

    private static func encode(_ image: CGImage) -> Data? {
        #if canImport(UIKit)
        return UIImage(cgImage: image).pngData()
        #else
        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(using: NSBitmapImageRep.FileType.png,
                                             properties: [NSBitmapImageRep.PropertyKey: Any]())
        #endif
    }
}

// MARK: - The view that gets rendered

/// The drawn avatar at rest on the banner plate.
///
/// Deliberately not `OpenBotAvatarView`: that view wraps its drawing in a `TimelineView`, which
/// `ImageRenderer` cannot sample — the same blank-picture failure the shape face hit with
/// `BotAvatarView`. This is the renderer's own entry point, called once, with no time.
private struct BotAvatarIconStill: View {
    let model: OpenBotAvatarModel
    let definition: BotAvatarDefinition
    let color: String?
    let material: BotAvatarMaterial
    let size: CGFloat

    var body: some View {
        let faceSide = size * BotAvatarIcon.faceInset
        // The plate is baked in for the same reason the shape face bakes it in: a banner shows the
        // picture over whatever wallpaper the phone has, and a warm face on nothing disappears.
        let plate = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
            .fill(LinearGradient(colors: [Tokens.surfaceRaised, Tokens.surface],
                                 startPoint: .top, endPoint: .bottom))
        let resolvedColor = color.flatMap(OpenBotAvatarColor.color(hex:))
            ?? OpenBotAvatarRenderer.defaultColor
        let ink = OpenBotAvatarView.ink(for: resolvedColor)

        ZStack {
            plate
            Canvas { context, canvasSize in
                // The rest pose: idle, neutral, no time. `reducedMotion` is what makes every wave
                // and breath zero, so two renders of one definition are the same bytes.
                let pose = OpenBotAvatarState.idle.pose(mood: .neutral,
                                                        time: 0,
                                                        seed: BotAvatarHash.shippedHash(definition.id),
                                                        reducedMotion: true)
                OpenBotAvatarRenderer.draw(model,
                                           pose: pose,
                                           material: material,
                                           // The plate is the dark surface pair, so glass is lit
                                           // against a dark backdrop — the same call the roster
                                           // makes on a dark page.
                                           backdrop: .themed(dark: true),
                                           into: &context,
                                           size: canvasSize,
                                           color: resolvedColor,
                                           ink: ink)
            }
            .frame(width: faceSide, height: faceSide)
        }
        .frame(width: size, height: size)
    }
}
