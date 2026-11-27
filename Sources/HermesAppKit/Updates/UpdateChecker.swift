#if canImport(Combine)
import Foundation
import Combine
import HermesKit

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
///
/// ## Why the offer can never move backwards
///
/// The feed is served by a CDN with a ten-minute cache, so a check in that window can see a document
/// written before the newest build was published. That must not turn into a chain of installs —
/// offer 583, install it, offer 584, install it — because each hop is a full signing cycle for the
/// owner. Every check therefore fetches with the caches bypassed, treats a 304 as "the bytes I have
/// are current" rather than "no update", offers the document's maximum build, and keeps the highest
/// build ever shown as a floor. The stored floor may refuse a stale offer; it may never choose one.
@MainActor
public final class UpdateChecker: ObservableObject {

    /// The stable keys. They are spelled out once here because a rename silently forgets every
    /// dismissal already recorded on a device.
    public enum DefaultsKey {
        public static let skippedBuild = "hermey.updates.skippedBuild"
        public static let lastCheck = "hermey.updates.lastCheck"
        /// The highest build this device has already been shown. A floor for the offer, never its
        /// source: `check` reads it only to discard an older document (see `highestOfferedBuild`).
        public static let highestOfferedBuild = "hermey.updates.highestOfferedBuild"
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

    /// Which presentation context the card belongs to.
    ///
    /// A sheet presented from a view that is itself covered by another sheet is not shown at all:
    /// it is queued, and it appears only when the covering sheet goes away. That was the whole of
    /// "I tapped Check for Updates, no Download button appeared, double-tapping did nothing, and the
    /// modal showed up after I closed Settings" — the card had been asked for by a view underneath
    /// the Settings sheet, so it waited there while the row already said an update existed.
    ///
    /// So the card is presented by the context that asked for it: a manual check comes from the
    /// Settings sheet and is shown over it, while the launch and foreground checks come from the app
    /// shell. Each presenter shows the card only for its own host, so exactly one of them acts and
    /// the other stays out of the way.
    public enum PromptHost: Sendable { case root, settings }

    @Published public private(set) var promptHost: PromptHost = .root

    /// Whether the launch screen has left and the app's own screen is on show.
    ///
    /// The card is never presented over the splash: a check that answers during boot is held until
    /// the fade is done, so the update appears on a screen the person can act on instead of behind a
    /// logo. `LaunchGateView` reports the moment; nothing is presented before it.
    @Published public private(set) var isShellReady = false


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

    /// The newest build this device has already put in front of the user.
    ///
    /// A floor, not a source. `check` compares a document's newest build against this to refuse one
    /// that is older than something already offered — it never reads this to choose the offer.
    /// `skippedBuild` counts too, so an install that predates this key (a device whose only memory
    /// is "I said not now to 691") does not get walked back to 680.
    public var highestOfferedBuild: Int {
        max(defaults.integer(forKey: DefaultsKey.highestOfferedBuild), skippedBuild ?? 0)
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
    /// - Parameter atLaunch: this is the check a cold start makes. It ignores the 24-hour throttle —
    ///   opening the app is the moment a person expects to be told about a new build, and a phone
    ///   opened twice in a minute costs one extra request, not one per launch of a session — while a
    ///   build the user already answered "Not now" to still stays answered (see `skippedBuild`).
    public func check(manual: Bool = false, atLaunch: Bool = false) async {
        // Two triggers can fire within a second of each other (launch and the first foreground
        // notification); one round trip answers both.
        guard !isChecking else { return }

        if !manual, !atLaunch, let lastCheck,
           Date().timeIntervalSince(lastCheck) < Self.minimumCheckInterval {
            return
        }

        isChecking = true
        defer { isChecking = false }

        let read = await latestUpdate()
        let installed = currentBuild

        // An attempt is what gets remembered, not a success: a feed that is down for a day must not
        // be re-asked on every foreground, and the next launch is the natural retry. A manual check
        // is never throttled, so it records nothing.
        if !manual {
            let now = Date()
            defaults.set(now, forKey: DefaultsKey.lastCheck)
            lastCheck = now
        }

        // Exactly one line per check, before any early return: URL, transport state, the build the
        // document carried, this install, and the offer made of it. A single line from a phone then
        // settles "where did this version come from".
        Self.logCheck(read, installed: installed,
                      decision: decision(for: read, installed: installed, manual: manual))

        guard let found = read.installable else {
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

        // A stale document (an edge-cached copy from before a publish) can advertise a build this
        // device was already shown something newer than. Discard it rather than walk the user
        // backwards through superseded versions; a newer card already on screen stays on screen.
        guard found.build >= highestOfferedBuild else {
            if let shown = available, shown.build > found.build { return }
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
        rememberOffered(found.build)
        // The card is shown by whoever asked: a manual check is made from inside the Settings
        // sheet, so it must be presented *there*, over the sheet the user is looking at.
        promptHost = manual ? .settings : .root
        isPromptVisible = true
    }

    /// What the check decided, in the words of its one log line.
    private func decision(for read: FeedRead, installed: Int, manual: Bool) -> String {
        guard let found = read.installable else { return "none (no installable entry)" }
        if found.build <= installed { return "none (installed \(installed))" }
        if found.build < highestOfferedBuild {
            return "none (stale: \(found.build) is behind \(highestOfferedBuild) already offered)"
        }
        if !manual, found.build == skippedBuild { return "none (skipped \(found.build))" }
        return "\(found.build) (\(found.version))"
    }

    /// Move a visible card to another presentation context, without withdrawing it.
    ///
    /// The case it exists for: the card was presented over the Settings sheet and the sheet was
    /// closed while the card was still up. The offer is then neither withdrawn nor recorded as "not
    /// now" — it continues over the app shell, which is what the user was left looking at.
    public func rehost(_ host: PromptHost) {
        guard isPromptVisible, promptHost != host else { return }
        promptHost = host
    }

    /// The launch screen has gone. A card that arrived during boot is presented now.
    ///
    /// Idempotent and safe to call on every launch: it only ever turns the gate on.
    public func shellDidReveal() {
        guard !isShellReady else { return }
        isShellReady = true
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

    /// One read of one feed, kept whole so the log can describe a check that produced no offer too.
    struct FeedRead {
        /// What the transport actually did, in the log's words.
        enum State: String {
            /// A 200 fetched from the origin/edge rather than replayed from a cache here.
            case fresh = "fresh-200"
            /// A 304 whose validated bytes were used — not "no update".
            case notModified = "notModified"
            /// A 304 whose body came from this device's `URLCache`: validated, then read locally.
            case cachedResponse = "cachedResponse"
            /// No response at all.
            case unreachable = "unreachable"
        }

        let url: URL?
        let state: State
        let status: Int?
        let age: Int?
        /// The newest build the document advertised, even when this platform cannot install it.
        let advertised: AvailableUpdate?
        /// The newest build the document advertised that this platform can install — the only
        /// thing that may become an offer.
        let installable: AvailableUpdate?

        static let none = FeedRead(url: nil, state: .unreachable, status: nil, age: nil,
                                   advertised: nil, installable: nil)

        func with(advertised: AvailableUpdate?, installable: AvailableUpdate?) -> FeedRead {
            FeedRead(url: url, state: state, status: status, age: age,
                     advertised: advertised, installable: installable)
        }
    }

    /// Fetch the source, then its fallback. Returns what the document said even when it held no
    /// installable entry, so the caller can log one line for every check.
    private func latestUpdate() async -> FeedRead {
        var last = FeedRead.none
        for url in [Self.sourceURL, Self.fallbackSourceURL].compactMap({ $0 }) {
            do {
                let fetched = try await fetch(url)
                let read = FeedRead(url: url, state: fetched.state, status: fetched.status,
                                    age: fetched.age, advertised: nil, installable: nil)
                guard let update = Self.update(in: fetched.data) else {
                    last = read
                    continue
                }
                // The document's newest entry is the candidate. Comfortably: `update(in:)` reduces
                // with `max`, so an intermediate version is never what comes back.
                last = read.with(advertised: update, installable: nil)
                // An entry this platform cannot install is not an update. The mac feed names a
                // `.dmg`; handing that to a phone opened a disk image in Safari, which is what
                // "it downloads the dmg instead of the ipa" was — the manifest, not the card.
                guard Self.isInstallable(update.url) else {
                    print("[updates] \(url.lastPathComponent) advertises "
                          + "\(update.url.lastPathComponent) — not installable here")
                    continue
                }
                last = last.with(advertised: update, installable: update)
                return last
            } catch {
                last = FeedRead(url: url, state: .unreachable, status: nil, age: nil,
                                advertised: nil, installable: nil)
                print("[updates] \(url.lastPathComponent) unavailable: \(error.localizedDescription)")
            }
        }
        return last
    }

    /// Whether this platform can install a feed's artifact.
    ///
    /// iOS installs a `.ipa` through a sideloading app and nothing else, so a `.dmg` from a shared
    /// feed is refused rather than offered. Other platforms keep the publisher's link: this checker
    /// is not the macOS updater (Sparkle is), and refusing a shape it does not know about would be
    /// this layer inventing a policy.
    static func isInstallable(_ url: URL) -> Bool {
#if os(iOS)
        return url.pathExtension.lowercased() == "ipa"
#else
        return true
#endif
    }

    /// The one line a check leaves in the `update` log.
    ///
    /// It names the URL, what the transport did, the newest build the document carried, the build
    /// running here, and the offer that came of it. One line from a phone answers "which document
    /// did it see, and why did it offer that version" without another round trip.
    static func logCheck(_ read: FeedRead, installed: Int, decision: String) {
        let advertised = read.advertised.map { "\($0.build) (\($0.version))" } ?? "none"
        let status = read.status.map { String($0) } ?? "-"
        let age = read.age.map { String($0) } ?? "-"
        ClientLog.note("\(read.url?.absoluteString ?? "no-url") "
                       + "state=\(read.state.rawValue) "
                       + "http=\(status) "
                       + "age=\(age) "
                       + "advertised=\(advertised) "
                       + "installed=\(installed) "
                       + "offer=\(decision)",
                       level: .info, category: "update")
    }

    /// Remember the build that was actually shown.
    ///
    /// Write-only from the offer's side: `check` reads `highestOfferedBuild` to refuse an older
    /// document, never to choose a newer one. The guard keeps it monotonic even if a stale value is
    /// somehow written later.
    private func rememberOffered(_ build: Int) {
        guard build > defaults.integer(forKey: DefaultsKey.highestOfferedBuild) else { return }
        defaults.set(build, forKey: DefaultsKey.highestOfferedBuild)
    }

    /// One read of the feed: bytes plus the transport facts the log needs.
    ///
    /// The request defeats every cache it can. `.reloadIgnoringLocalAndRemoteCacheData` empties our
    /// `URLCache` for this request and asks intermediaries not to answer from their copy; the
    /// headers say it again for edges that only read them; and the `cb` query is a cache key no
    /// earlier request used. None of the three changes which file GitHub Pages serves, and the
    /// manifest's own `downloadURL` is never rewritten.
    private func fetch(_ url: URL) async throws -> (data: Data, state: FeedRead.State,
                                                   status: Int, age: Int?) {
        var request = URLRequest(url: Self.cacheBusted(url),
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 15)
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateFeedError.badStatus(-1)
        }
        let age = http.value(forHTTPHeaderField: "Age").flatMap { Int($0) }
        switch http.statusCode {
        case 200 ..< 300:
            return (data, .fresh, http.statusCode, age)
        case 304:
            // A 304 means the copy the server holds is still current, not that there is no update.
            // Use the bytes the server just validated; only when neither the response nor the cache
            // carries them is this a failure. Returning nil here would be the bug this fixes.
            if !data.isEmpty { return (data, .notModified, http.statusCode, age) }
            if let cached = URLCache.shared.cachedResponse(for: URLRequest(url: url))?.data,
               !cached.isEmpty {
                return (cached, .cachedResponse, http.statusCode, age)
            }
            throw UpdateFeedError.notModifiedWithoutBody
        default:
            throw UpdateFeedError.badStatus(http.statusCode)
        }
    }

    /// The same manifest under a query no cache has seen.
    ///
    /// GitHub Pages routes on the path and serves the same file, so this cannot break the manifest;
    /// it only prevents a stale cache key from being reused.
    static func cacheBusted(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "cb" }
        items.append(URLQueryItem(name: "cb", value: String(Int(Date().timeIntervalSince1970))))
        components.queryItems = items
        return components.url ?? url
    }

    enum UpdateFeedError: Error {
        case badStatus(Int)
        /// A 304 arrived and neither the response nor the cache carried the validated bytes.
        case notModifiedWithoutBody
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
