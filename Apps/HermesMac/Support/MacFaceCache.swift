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
/// `PushIcon.png` is the renderer, and the reason is the same as on iOS: `BotAvatarView` animates
/// inside a `TimelineView`, which `ImageRenderer` cannot sample, so sampling it produced a blank
/// picture and every banner lost its face.
@MainActor
enum MacFaceCache {

    /// The face for a bot, as a notification attachment.
    ///
    /// The cache file is keyed by the bot *and* the stored face: changing a bot's face from its
    /// settings must change the next banner, not wait for the caches folder to be cleared.
    static func attachment(for botID: String, color: String?) -> UNNotificationAttachment? {
        let url = cacheDirectory().appendingPathComponent("\(slug(botID, color)).png")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard let png = PushIcon.png(for: botID, color: color) else { return nil }
            try? FileManager.default.createDirectory(at: cacheDirectory(),
                                                     withIntermediateDirectories: true)
            try? png.write(to: url, options: .atomic)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? UNNotificationAttachment(identifier: "face-\(botID)", url: url, options: nil)
    }

    /// A file name that carries the face without ever breaking: bot ids and `#RRGGBB::shape_N`
    /// both contain characters a path should not.
    private static func slug(_ botID: String, _ color: String?) -> String {
        let face = (color ?? "derived").replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return "\(botID)-\(face)"
    }

    private static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("bot-faces", isDirectory: true)
    }
}
