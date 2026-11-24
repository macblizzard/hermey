import Foundation
import SwiftUI
import HermesKit
import HermeyUI
#if os(iOS)
import UIKit

/// The bot's own face, on disk, for banners.
///
/// A local notification can only carry a *picture*, never an app icon of its choosing — iOS draws the
/// banner's corner icon from the app bundle and nothing can change that per notification. So the face
/// goes inside the banner as an attachment, rendered once per face and cached as a file: the
/// background sweep posts from a non-main context where SwiftUI cannot render, and a notification
/// that is already due must not wait on layout.
///
/// The picture comes from `PushIcon`, which asks the bot's *drawn* avatar first — so a bot with a
/// stored definition gets its own face here, and a bot without one gets the shape face exactly as
/// before. Nothing in this type decides which; the file is just the bytes `PushIcon` returned.
enum MobileFaceCache {

    /// Rendering is main-actor work (`ImageRenderer`), so the cache is filled at launch and on a
    /// save — never while a notification is being posted.
    ///
    /// Every bot the host knows about is visited, including one that has an avatar but no stored
    /// shape (`faces` and `avatars` are unioned): a bot that saved a definition must not depend on
    /// the older face map having a row for it.
    @MainActor
    static func refresh(faces: [String: BotFaceChoice],
                        avatars: [String: BotAvatarDocument]) async {
        let directory = cacheDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for botID in Set(faces.keys).union(avatars.keys) {
            guard let png = PushIcon.png(for: botID,
                                         avatar: avatars[botID],
                                         color: faces[botID]?.raw) else { continue }
            let url = directory.appendingPathComponent("\(botID).png")
            // Unchanged faces cost nothing: same bytes, no write.
            if let existing = try? Data(contentsOf: url), existing == png { continue }
            try? png.write(to: url, options: .atomic)
        }
    }

    /// The face for a bot, or nil when it has never been rendered (a brand-new bot before the next
    /// launch). A banner without a picture is the right failure: no banner is worse.
    static func data(for botID: String) -> Data? {
        try? Data(contentsOf: cacheDirectory().appendingPathComponent("\(botID).png"))
    }

    /// A notification attachment needs a file URL, and the system takes its own copy.
    ///
    /// A read, never a render: this runs while a banner is being posted, and a render there would
    /// put `ImageRenderer` between the reply and the notification.
    static func attachment(for botID: String) -> UNNotificationAttachment? {
        let url = cacheDirectory().appendingPathComponent("\(botID).png")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? UNNotificationAttachment(identifier: "face-\(botID)", url: url, options: nil)
    }

    /// Drop one bot's cached face after its avatar was saved or cleared.
    ///
    /// Without this a cleared definition would keep serving the drawn face until the file was
    /// rewritten, and a saved one could keep the previous body if the new render happened to answer
    /// the same bytes. The renderer's in-memory cache is cleared at the same time, so the next
    /// `refresh` really redraws.
    @MainActor
    static func invalidate(botID: String) {
        try? FileManager.default.removeItem(at: cacheDirectory().appendingPathComponent("\(botID).png"))
        PushIcon.invalidate(botID: botID)
    }

    /// Drop every cached face: unpairing or switching hosts.
    @MainActor
    static func invalidateAll() {
        try? FileManager.default.removeItem(at: cacheDirectory())
        PushIcon.invalidateAll()
    }

    private static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("bot-faces", isDirectory: true)
    }
}
#endif
