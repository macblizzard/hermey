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
enum MobileFaceCache {

    /// Rendering is main-actor work (`ImageRenderer`), so the cache is filled at launch and read from
    /// anywhere afterwards.
    @MainActor
    static func refresh(faces: [String: BotFaceChoice]) async {
        let directory = cacheDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (botID, face) in faces {
            guard let png = PushIcon.png(for: botID, color: face.raw) else { continue }
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
    static func attachment(for botID: String) -> UNNotificationAttachment? {
        let url = cacheDirectory().appendingPathComponent("\(botID).png")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? UNNotificationAttachment(identifier: "face-\(botID)", url: url, options: nil)
    }

    private static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("bot-faces", isDirectory: true)
    }
}
#endif
