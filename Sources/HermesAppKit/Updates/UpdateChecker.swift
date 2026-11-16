#if canImport(Combine)
import Foundation
import Combine

/// One "a newer build than this one exists" fact, already parsed and checked as far as the app can.
///
/// The values come from the published feed and are carried unchanged: the version string is the
/// publisher's, the build is the integer the comparison uses, and `url` is exactly the URL the feed
/// advertised. Nothing here is derived, so a wrong link is the publisher's wrong link and not a
/// second opinion the app invented.
public struct AvailableUpdate: Identifiable, Equatable, Sendable {
    /// The human-facing version — shown, never compared. Whether it is newer is `build`'s job.
    public let version: String
    /// `CFBundleVersion`'s counterpart: the integer that decides "newer".
    public let build: Int
    /// The IPA's own URL, opened in Safari by the caller. Never rewritten here.
    public let url: URL
    /// What the publisher measured, for the card's caption. Zero when the feed omitted it.
    public let size: Int
    /// The publisher's digest, shown for the record. The app does not download, so it cannot verify it.
    public let sha256: String
    /// What changed in this build — the publisher's release notes, shown in the card. Empty when the
    /// feed carried none, which is a card without a list rather than a card without an update.
    public let notes: String

    public var id: Int { build }

    public init(version: String, build: Int, url: URL, size: Int, sha256: String,
                notes: String = "") {
        self.version = version
        self.build = build
        self.url = url
        self.size = size
        self.sha256 = sha256
        self.notes = notes
    }
}

/// Watches the published sideload source for a build newer than the one running.
///
/// ## Why this is not a downloader
///
/// iOS cannot replace its own bundle: a sideloaded app has no API to install over itself. So the
/// honest shape of "update" on this platform is *tell the user, and open the IPA's URL* — Safari
/// hands it to AltStore (or Files), which does the installing. Nothing here downloads, stages or
/// installs anything, and there is no path that does.
///
/// ## Why every failure is silent
///
/// The unsolicited check runs on launch and on foreground, where the user asked for a chat app and
/// not for a network diagnosis. A feed that is unreachable, slow, or briefly serving an old
/// manifest is not their problem: it is recorded in the log and the app carries on. A manual check
/// still reports through `isChecking` and the absence of an offered update, so the row in Settings
/// is never a dead button that says nothing.
///
/// ## Why the skip and the throttle live in `UserDefaults`
///
/// Dismissal has to survive a relaunch — that is the entire promise of "Not now" — and a 24-hour
/// throttle has to survive one too, or a phone that is opened and closed twenty times a day makes
/// twenty feed requests. Both are two values, so they are stored beside the app's other preferences
/// rather than in a file of their own.
@MainActor
public final class UpdateChecker: ObservableObject {

    /// The stable keys. They are spelled out once here because a rename silently forgets every
    /// dismissal already recorded on a device.
    public enum DefaultsKey {
        public static let skippedBuild = "hermey.updates.skippedBuild"
        public static let lastCheck = "hermey.updates.lastCheck"
    }

    /// One unsolicited check a day. A manual check is never throttled: the person tapping the row
    /// has already answered "do you want to ask now".
    public static let minimumCheckInterval: TimeInterval = 24 * 60 * 60

    /// The AltStore-style source GitHub Pages serves. The iOS entry is the truth for this platform:
    /// it names the IPA, while `mac.json` names the DMG.
    public static let sourceURL = URL(string: "https://macblizzard.github.io/hermey-downloads/altstore.json")

    /// The notifier feed, used only when the AltStore document cannot be fetched or parsed. Both are
    /// written by one publish from one measurement, so either carries the same build.
    public static let fallbackSourceURL = URL(string: "https://macblizzard.github.io/hermey-downloads/mac.json")

    /// The update to offer, or nil. Cleared when the feed stops advertising something newer than
    /// this build, so a stale card cannot survive a downgrade.
    @Published public private(set) var available: AvailableUpdate?

    /// Whether the card is on screen. Kept beside `available` because the offer and the sheet are
    /// two facts: a manual check can re-offer a build the user skipped without the app deciding on
    /// its own to put a card over their chat.
    @Published public private(set) var isPromptVisible = false

    /// A check is in flight. The Settings row reads this to say so instead of looking unresponsive.
    @Published public private(set) var isChecking = false

    /// When the last *unsolicited* check completed. Nil until one has.
    @Published public private(set) var lastCheck: Date?

    private let defaults: UserDefaults
    private let session: URLSession

    public init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        self.lastCheck = defaults.object(forKey: DefaultsKey.lastCheck) as? Date
    }

    // MARK: What this build is

    /// `CFBundleVersion` as an integer, or 0 when the bundle does not carry a usable one.
    ///
    /// Zero is treated as "unknown" by `check`, never as "the oldest build": an unreadable version
    /// must not be the reason a card appears over the app.
    public var currentBuild: Int {
        guard let text = Self.bundleString("CFBundleVersion") else { return 0 }
        return Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// `CFBundleShortVersionString`, or an em dash when the bundle has none (a preview, a test host).
    public var currentVersion: String {
        guard let text = Self.bundleString("CFBundleShortVersionString"), !text.isEmpty else { return "—" }
        return text
    }

    /// The build the user said "not now" to. Read back on every launch, which is what keeps the same
    /// card from appearing twice.
    public var skippedBuild: Int? {
        let recorded = defaults.integer(forKey: DefaultsKey.skippedBuild)
        return recorded > 0 ? recorded : nil
    }

    private static func bundleString(_ key: String) -> String? {
        guard let value = Bundle.main.infoDictionary?[key] else { return nil }
        // `CFBundleVersion` is a string by convention but an `NSNumber` in a bundle built straight
        // from a plist literal, and `as? String` on that returns nil.
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    // MARK: Checking

    /// Ask the feed, and offer the result when it is newer.
    ///
    /// - Parameter manual: a person tapped "Check for Updates". A manual check ignores both the
    ///   24-hour throttle and the remembered skip, because it is an explicit request to be told.
    public func check(manual: Bool = false) async {
        // Two triggers can fire within a second of each other (launch and the first foreground
        // notification); one round trip answers both.
        guard !isChecking else { return }

        if !manual, let lastCheck, Date().timeIntervalSince(lastCheck) < Self.minimumCheckInterval {
            return
        }

        isChecking = true
        defer { isChecking = false }

        let found = await latestUpdate()

        // The attempt is what gets remembered, not the success: a feed that is down for a day must
        // not be re-asked on every foreground, and the next launch is the natural retry.
        if !manual {
            let now = Date()
            defaults.set(now, forKey: DefaultsKey.lastCheck)
            lastCheck = now
        }

        guard let found else {
            // Nothing newer, or nothing reachable. A stale offer is withdrawn either way.
            available = nil
            isPromptVisible = false
            return
        }

        guard found.build > currentBuild else {
            available = nil
            isPromptVisible = false
            return
        }

        // Unsolicited: a build the user already declined stays declined until a newer one appears.
        // Manual: the request was "tell me", so the skip does not apply.
        if !manual, found.build == skippedBuild {
            available = nil
            isPromptVisible = false
            return
        }

        available = found
        isPromptVisible = true
    }

    /// The user dismissed the card — "Not now", Cancel, Escape or a swipe all land here.
    ///
    /// The build is recorded before the sheet closes so a swipe-down (which never runs a button's
    /// action) is remembered exactly like the button. `available` is kept so the Settings row can
    /// still say an update exists; only the card goes away.
    public func dismissPrompt() {
        if let available {
            defaults.set(available.build, forKey: DefaultsKey.skippedBuild)
        }
        isPromptVisible = false
    }

    /// The user chose Download. The card closes but nothing is skipped: an update that was opened
    /// and not installed should still be offered next launch.
    public func promptHandedOff() {
        isPromptVisible = false
    }

    // MARK: The feed

    /// Fetch the source, then its fallback. Every error path ends in nil and one log line.
    private func latestUpdate() async -> AvailableUpdate? {
        for url in [Self.sourceURL, Self.fallbackSourceURL].compactMap({ $0 }) {
            do {
                let data = try await fetch(url)
                if let update = Self.update(in: data) { return update }
            } catch {
                print("[updates] \(url.lastPathComponent) unavailable: \(error.localizedDescription)")
            }
        }
        return nil
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // A manual check means "what does the server say now"; a cached manifest would answer with
        // the build the person is already running.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw UpdateFeedError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    enum UpdateFeedError: Error {
        case badStatus(Int)
    }

    /// Parse either feed shape and return its newest entry, or nil when neither shape is present.
    ///
    /// Both are tried on the same bytes: `altstore.json` is a document of documents, `mac.json` is a
    /// single object, and a publisher that wrote one where the other was expected is a parse problem
    /// the app can absorb. Entries whose build is not an integer are dropped rather than treated as
    /// zero — an unparseable build is not "older than everything", and it is certainly not newer.
    static func update(in data: Data) -> AvailableUpdate? {
        let decoder = JSONDecoder()

        if let document = try? decoder.decode(AltStoreDocument.self, from: data) {
            let entries = (document.apps ?? []).flatMap { $0.versions ?? [] }
            let candidates: [AvailableUpdate] = entries.compactMap { entry in
                guard let build = entry.buildVersion?.value, build > 0,
                      let version = entry.version, !version.isEmpty,
                      let text = entry.downloadURL,
                      let url = secureURL(text) else { return nil }
                return AvailableUpdate(version: version,
                                       build: build,
                                       url: url,
                                       size: entry.size ?? 0,
                                       sha256: entry.sha256 ?? "",
                                       notes: entry.localizedDescription ?? "")
            }
            if let newest = candidates.max(by: { $0.build < $1.build }) { return newest }
        }

        if let document = try? decoder.decode(MacDocument.self, from: data),
           let build = document.build?.value, build > 0,
           let version = document.version, !version.isEmpty,
           let text = document.url, let url = secureURL(text) {
            return AvailableUpdate(version: version,
                                   build: build,
                                   url: url,
                                   size: document.size ?? 0,
                                   sha256: document.sha256 ?? "",
                                   notes: document.notes ?? "")
        }

        return nil
    }

    /// Only HTTPS survives.
    ///
    /// The app does not follow this URL itself — it hands it to the system — so it cannot police
    /// the final host. Requiring TLS is the one check that still means something at this layer, and
    /// a plain-http install link from a feed is a mistake worth refusing rather than opening.
    static func secureURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

// MARK: - Feed shapes

/// `altstore.json`: `{"apps": [{"versions": [{version, buildVersion, downloadURL, size, sha256}]}]}`.
///
/// Every field is optional because a malformed entry should cost that entry, not the whole document:
/// decoded strictly, one missing `sha256` would turn "an update exists" into "the feed is broken".
private struct AltStoreDocument: Decodable {
    struct App: Decodable {
        let versions: [Version]?
    }

    struct Version: Decodable {
        let version: String?
        let buildVersion: BuildNumber?
        let downloadURL: String?
        let size: Int?
        let sha256: String?
        /// The publisher's release notes for this build — what changed, in the card.
        let localizedDescription: String?
    }

    let apps: [App]?
}

/// `mac.json`: one object, `{version, build, size, sha256, url, publishedAt, notes}`.
private struct MacDocument: Decodable {
    let version: String?
    let build: BuildNumber?
    let url: String?
    let size: Int?
    let sha256: String?
    /// The same notes as the AltStore document carries, under the key this feed uses.
    let notes: String?
}

/// A build number as either a JSON string or a number.
///
/// AltStore's own sources write strings; a hand-edited or differently generated manifest may write
/// an integer, and `"484"` vs `484` must not be the difference between an offered update and none.
private struct BuildNumber: Decodable {
    let value: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = Int(text.trimmingCharacters(in: .whitespaces))
        } else if let number = try? container.decode(Int.self) {
            value = number
        } else {
            value = nil
        }
    }
}
#endif
