import Foundation
import HermesKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// One remote picture for an `infographic` card, and the store that keeps it.
///
/// The bytes take the path the transcript's own pictures already take: `AttachmentImageStore` is the
/// cache — the same on-disk folder and 240-file prune — so a card's hero image is a *reader* of the
/// existing picture pipeline rather than a second one. A small memory copy in front of it keeps a
/// card that scrolls out and back from going to disk again.
///
/// Everything is `@MainActor` because the only caller is a view: the network read suspends, so
/// nothing blocks, and no `Sendable` gymnastics are needed for a type that never leaves the main
/// actor.
@MainActor
enum CardImageLoader {

    /// A phone-sized picture, not a document: past this the card draws its caption alone rather
    /// than pull tens of megabytes into memory for a 170-point frame.
    static let maximumBytes = 8 * 1024 * 1024

    /// What the request may take before the card gives up and shows the caption. Shorter than the
    /// session's default: a card is a glance, and a picture that arrives after the owner has moved on
    /// is a picture nobody wanted.
    static let timeout: TimeInterval = 12

    /// Enough for a transcript's worth of cards, small enough to stay a cache.
    private static let keep = 24
    private static var memory: [String: CardImage] = [:]

    /// A picture already decoded this session, without touching the disk. A card that scrolls out
    /// and back draws immediately rather than flashing its skeleton again.
    static func cached(for url: URL) -> CardImage? {
        memory[cacheName(for: url)]
    }

    /// The picture, from memory, then the disk cache, then the network. `nil` is the failure
    /// answer — the view draws the caption and nothing else.
    static func image(for url: URL) async -> CardImage? {
        let key = cacheName(for: url)
        if let hit = memory[key] { return hit }
        if let data = AttachmentImageStore.data(named: key), let decoded = CardImage(data: data) {
            store(decoded, for: key)
            return decoded
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .returnCacheDataElseLoad
        // A picture is not a page: no cookies, no referrer, nothing that could carry a session to a
        // third-party image host.
        request.httpShouldHandleCookies = false

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count <= maximumBytes,
              let decoded = CardImage(data: data) else { return nil }

        AttachmentImageStore.save(data, as: key)
        store(decoded, for: key)
        return decoded
    }

    private static func store(_ image: CardImage, for key: String) {
        if memory.count >= keep { memory.removeAll(keepingCapacity: true) }
        memory[key] = image
    }

    /// A single file name, because `AttachmentImageStore` keeps only the last path component: the
    /// host plus the file's own name, so two sites' `image.jpg` cannot land on one cache entry.
    static func cacheName(for url: URL) -> String {
        let host = url.host ?? "remote"
        let file = url.lastPathComponent.isEmpty ? "image" : url.lastPathComponent
        let safe = "infographic-\(host)-\(file)".map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-" || character == "_"
                ? character
                : "_"
        }
        return String(String(safe).prefix(120))
    }
}

/// A decoded picture, ready to draw.
struct CardImage {
    let image: Image

    /// `nil` for bytes that are not a picture: an HTML error page served with a `200` and an
    /// `image/jpeg` type is the common case, and it must not become a grey box.
    init?(data: Data) {
        #if canImport(UIKit)
        guard let decoded = UIImage(data: data) else { return nil }
        self.image = Image(uiImage: decoded)
        #else
        guard let decoded = NSImage(data: data) else { return nil }
        self.image = Image(nsImage: decoded)
        #endif
    }
}
