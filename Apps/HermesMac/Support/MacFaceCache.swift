import AppKit
import Foundation
import HermeyUI
import UserNotifications

/// The bot's own face, on disk, for banners.
///
/// A notification can only carry a *picture*, never an app icon of its choosing: macOS draws the
/// banner's corner from the app bundle, and nothing changes that per notification. So the face goes
/// inside the banner as an attachment, exactly as the phone does it — rendered once per face and
/// cached as a file, because a banner is posted while the app is in the background and must not wait
/// on layout.
///
/// `PushIcon.png` is the renderer, and it asks the bot's drawn avatar first: a bot with a stored
/// definition gets that face here, and a bot without one gets the shape face exactly as before.
/// `BotAvatarView` cannot be sampled (`TimelineView`), which is why the picture is made through the
/// still renderers rather than by photographing the roster.
///
/// **Posting never renders.** `attachment(for:)` is a file read; `refresh(faces:avatars:)` is the
/// one sweep that draws, run at launch and after an avatar is saved. Rendering inside `post` put
/// `ImageRenderer` between a reply and its banner, on the main thread, for a bot whose face had not
/// been drawn yet.
@MainActor
enum MacFaceCache {

    /// The renderer's schema. Commit `60a2993` changed the face model and the app icon, but a cached
    /// PNG from the old one kept being attached to banners (reported 2026-11-17: banners still wore
    /// the old logo). `v3` is the first schema whose file can hold a drawn avatar, and the first keyed
    /// by the bot alone: the face is kept current by rewriting the one file on save, so a stale face
    /// is impossible rather than merely unlikely. Bump this when the picture's *shape* changes.
    private static let schema = "v3"

    /// Render every bot's face that is not already on disk, byte for byte.
    ///
    /// Called at launch and after a save, never from `post`. The union of `faces` and `avatars` is
    /// deliberate: a bot that saved a definition must get a picture whether or not the older face map
    /// has a row for it, and a bot that has one needs no definition to keep the shape face it had.
    static func refresh(faces: [String: BotFaceChoice],
                        avatars: [String: BotAvatarDocument]) async {
        let directory = cacheDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for botID in Set(faces.keys).union(avatars.keys) {
            guard let png = PushIcon.png(for: botID,
                                         avatar: avatars[botID],
                                         color: faces[botID]?.raw) else { continue }
            let url = directory.appendingPathComponent("\(schema)-\(stem(botID)).png")
            // Same bytes, no write: a launch sweep over twenty unchanged bots is twenty reads.
            if let existing = try? Data(contentsOf: url), existing == png { continue }
            try? png.write(to: url, options: .atomic)
        }
    }

    /// The face for a bot, as a notification attachment — a read, never a render.
    static func attachment(for botID: String) -> UNNotificationAttachment? {
        let url = cacheDirectory().appendingPathComponent("\(schema)-\(stem(botID)).png")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? UNNotificationAttachment(identifier: "face-\(botID)", url: url, options: nil)
    }

    /// Drop one bot's cached face after its avatar was saved or cleared, and forget the renderer's
    /// bytes at the same time so the next `refresh` really redraws.
    static func invalidate(botID: String) {
        try? FileManager.default.removeItem(at: cacheDirectory()
            .appendingPathComponent("\(schema)-\(stem(botID)).png"))
        PushIcon.invalidate(botID: botID)
    }

    /// Drop every cached face: unpairing or switching hosts.
    static func invalidateAll() {
        try? FileManager.default.removeItem(at: cacheDirectory())
        PushIcon.invalidateAll()
    }

    /// A file name that carries the bot without ever breaking: a bot id is a slug, but the cache must
    /// not be the thing that turns a bad one into a path traversal.
    private static func stem(_ botID: String) -> String {
        botID.replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }

    private static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("bot-faces", isDirectory: true)
    }
}
