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
/// Dismissal has to survive a relaunch — that is the entire promise of "Not now". It is one value, so
/// it is stored beside the app's other preferences rather than in a file of its own.
///
/// The *throttle* deliberately does not live there. A timestamp that outlives the app can only ever
/// refuse the next thing the person does, and on this platform that next thing is almost always
/// "open the app": iOS resumes far more often than it cold-starts, `scenePhase` goes `.active`
/// without a launch, and a 24-hour gate on that path meant a build published at 12:44 stayed
/// invisible at 18:00 on a device whose last check was 12:25 — the log held one `offer=none` line
/// from before the publish and nothing after it. So the only bound left is a short one held in
/// memory (`repeatCheckInterval`), which cannot outlive the session and therefore cannot silence a
/// launch or a return to the front.
///
/// ## Why the offer can never move backwards, and can never be refused by history
///
/// The feed is served by a CDN with a ten-minute cache, so a check in that window can see a document
/// written before the newest build was published. That must not turn into a chain of installs —
/// offer 583, install it, offer 584, install it — because each hop is a full signing cycle for the
/// owner. Every check therefore fetches with the caches bypassed, treats a 304 as "the bytes I have
/// are current" rather than "no update", and offers the document's maximum build.
///
/// The earlier guard against that was a stored floor: the highest build ever offered, which could
/// refuse a document older than it. It was removed. A stored number cannot tell a genuinely stale
/// document from a feed that has *moved on*, and when it sat above the feed's newest build it
/// silently refused real releases — a phone on 692 reading a document that said 693 and being told
/// there was nothing, with no line anywhere saying why. What protects the screen now is only what is
/// true at this moment: the document in hand, the build running, an explicit "Not now" for exactly
/// that build, and a card already on screen that a stale copy must not retract.
@MainActor
public final class UpdateChecker: ObservableObject {

    /// The stable keys. They are spelled out once here because a rename silently forgets every
    /// dismissal already recorded on a device.
    public enum DefaultsKey {
        public static let skippedBuild = "hermey.updates.skippedBuild"
        /// When the last unsolicited check completed, across launches. Recorded for the log and for
        /// any future background path; it is never what decides whether a launch asks.
        public static let lastCheck = "hermey.updates.lastCheck"
        /// The highest build this device has already been shown. Recorded for the log; it is never
        /// compared against a document to refuse one (see `highestOfferedBuild`).
        public static let highestOfferedBuild = "hermey.updates.highestOfferedBuild"
    }

    /// The only throttle left: fifteen minutes between unsolicited checks *inside one run of the app*.
    ///
    /// It exists for one thing — a foreground toggle loop, which a person switching apps can drive
    /// dozens of times a minute — and it is deliberately not persisted, so a check from an earlier
    /// session can never refuse the launch or the foreground entry that follows it. A launch and a
    /// return to the front are user-visible events and are always asked. A manual check is never
    /// throttled at all: the person tapping the row has already answered "do you want to ask now".
    public static let repeatCheckInterval: TimeInterval = 15 * 60

    /// The AltStore-style source GitHub Pages serves. The iOS entry is the truth for this platform:
    /// it names the IPA, while `mac.json` names the DMG.
    ///
    /// This is the app feed and it is always current: every publish rewrites this one file, from one
    /// measurement. It is tried first because the release asset it once pointed at cannot be: GitHub
    /// marks *whichever* release is newest as `latest`, every publish also cuts a `hermeyd-v*`
    /// release for the host, and that release carries no `altstore.json` asset at all — so `latest`
    /// frequently answered 404 and the real feed was never tried.
    public static let sourceURL = URL(string: "https://macblizzard.github.io/hermey-downloads/altstore.json")

    /// The release asset, kept as a fallback. It is the same document when the newest release *is*
    /// an app release; when a `hermeyd-v*` release is `latest` it answers 404 and the check moves on.
    public static let releaseSourceURL = URL(string: "https://github.com/macblizzard/hermey/releases/latest/download/altstore.json")

    /// The notifier feed, last. Both documents are written by one publish from one measurement, so
    /// either carries the same build — but on iOS the `.dmg` this names is refused by
    /// `isInstallable`, so it can only end a check with a stated reason, never with an offer.
    public static let fallbackSourceURL = URL(string: "https://macblizzard.github.io/hermey-downloads/mac.json")

    /// The documents a check reads, in order. The Pages feed is first because it is the only URL
    /// that is always the app feed; the release asset and the Mac document are fallbacks, and the
    /// check says in its log which one answered.
    static var feedURLs: [URL] {
        [Self.sourceURL, Self.releaseSourceURL, Self.fallbackSourceURL].compactMap { $0 }
    }

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
    ///
    /// Published for the Settings row and recorded across launches for the log. It does not gate
    /// anything: `check` never reads it to decide whether to ask.
    @Published public private(set) var lastCheck: Date?

    /// When this run of the app last started an unsolicited check.
    ///
    /// In memory on purpose. A fresh launch begins with no memory, so the launch check cannot be
    /// refused by a check made yesterday, and the foreground entry a second later is one request
    /// rather than two.
    private var lastUnsolicitedCheck: Date?

    /// A manual press that landed while a check was already in flight.
    ///
    /// The press does not need its own round trip — the check running is reading the same document
    /// seconds old — but it does change how that answer is presented, which is what made "Check now"
    /// look dead: the launch check settled with `promptHost = .root`, so the card it offered was
    /// asked for by the shell and queued *behind* the Settings sheet the press came from. Consumed
    /// by the one `check` that is running: the answer is presented over Settings and an earlier
    /// "Not now" for exactly this build does not swallow an answer the person just asked for. It is
    /// cleared the moment it is read, and a manual press can only observe it between the in-flight
    /// check's awaits, so the running check always consumes it — it cannot leak into a later
    /// unsolicited check.
    private var manualJoinsCheck = false

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
    /// A record, not a veto. It is written when an offer is shown and printed in the check log, and
    /// nothing compares it against a document to refuse one — a stored number above the feed's
    /// newest build would otherwise be indistinguishable from a stale feed and would silence a real
    /// release. What protects the screen from a stale document is the card that is *up* (see
    /// `settle`), which is live evidence rather than a remembered number.
    /// `skippedBuild` counts too, so the record describes what this device answered.
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

    /// What the last check actually established, in words a row can print.
    ///
    /// The reason this exists: "no card appeared" used to be the *only* signal, and it is the same
    /// signal for five different facts — the device is current, the feed was unreachable, the newest
    /// entry cannot be installed here, the user declined this build, or nothing was read at all.
    /// A person pressing "Check for Updates" and seeing the build they already have reads that as
    /// "up to date", so a check that failed or was vetoed was indistinguishable from a true negative.
    public enum CheckOutcome: Equatable, Sendable {
        /// The fresh document's newest *installable* build is this one or older. Only this case may
        /// be reported as "up to date".
        case upToDate(newest: Int, installed: Int)
        /// A newer build was offered (and, unsolicited, not already declined).
        case offered(AvailableUpdate)
        /// The document's newest build cannot be installed on this platform — a `.dmg` on a phone.
        /// A document was read; it just names something this app cannot hand to a sideloader.
        case notInstallable(advertised: Int)
        /// No document at all: every feed failed to answer, or answered without a parsable entry.
        case unreachable
        /// The document names a newer build, and this device already said "Not now" to exactly it.
        case declined(build: Int)
    }

    /// The outcome of the most recent completed check, or nil before the first one finishes.
    @Published public private(set) var outcome: CheckOutcome?

    /// Ask the feed, and offer the result when it is newer.
    ///
    /// - Parameter manual: a person tapped "Check for Updates". A manual check ignores both the
    ///   throttle and the remembered skip, because it is an explicit request to be told.
    /// - Parameter atLaunch: this is the check a cold start makes. It never consults the throttle —
    ///   opening the app is the moment a person expects to be told about a new build — and it says
    ///   so in the log (`update: launch check (throttle=skipped)`) so a device's log proves which
    ///   path ran. A build the user already answered "Not now" to still stays answered (see
    ///   `skippedBuild`); that is the only history an offer respects.
    ///
    /// What is *not* consulted, by any path: `lastCheck` and `highestOfferedBuild`. A number from an
    /// earlier session is a record, never a gate — a fresh document newer than the build running
    /// here is news, and no stored value may refuse it.
    public func check(manual: Bool = false, atLaunch: Bool = false) async {
        var source = manual ? "manual" : (atLaunch ? "launch" : "foreground")

        // Two triggers can fire within a second of each other (launch and the first foreground
        // notification); one round trip answers both.
        guard !isChecking else {
            if manual {
                // A press that lands on a check already in flight joins it — not dropped, and not
                // folded in silence: the answer in flight is about the same document, but the press
                // changes how it is presented and which history it respects (see
                // `manualJoinsCheck`). The row is showing "Checking…", and this check will settle
                // it with the press's answer over the Settings sheet it came from.
                manualJoinsCheck = true
                Self.note("update: check(source=manual) joins=in-flight")
            }
            return
        }

        if !manual {
            if atLaunch {
                // Named before any work, so a launch that goes on to find nothing still proves the
                // launch path reached the feed instead of being swallowed by a clock.
                Self.note("update: launch check (throttle=skipped)")
            } else if let previous = lastUnsolicitedCheck,
                      Date().timeIntervalSince(previous) < Self.repeatCheckInterval {
                // The one skip left, and it can only ever repeat an answer this session already has.
                Self.note("update: foreground check (throttle=hit, "
                          + "\(Int(Date().timeIntervalSince(previous)))s since the last check)")
                return
            } else {
                Self.note("update: foreground check (throttle=fresh)")
            }
        }

        isChecking = true
        defer { isChecking = false }
        if !manual { lastUnsolicitedCheck = Date() }

        let read = await latestUpdate()
        let installed = currentBuild

        // An attempt is what gets remembered, not a success: a feed that is down for a day must not
        // be re-asked on every foreground, and the next launch is the natural retry. A manual check
        // is never throttled, so it records nothing. The value is written for the log and the
        // Settings row — nothing reads it to decide whether to ask.
        if !manual {
            let now = Date()
            defaults.set(now, forKey: DefaultsKey.lastCheck)
            lastCheck = now
        }

        let floor = highestOfferedBuild
        // A manual press that joined this check rides on its answer: the join flag is consumed here,
        // once, before the decision — the offer is presented over Settings and a recorded skip does
        // not apply to it. `manual` alone still decides what the unsolicited check does.
        let asked = manual || manualJoinsCheck
        if manualJoinsCheck {
            source += "+manual"
            manualJoinsCheck = false
        }
        let settled = settle(read, installed: installed, manual: asked)
        outcome = settled.outcome

        // Exactly one measurement line per check: the source, URL, transport state, the build the
        // document advertised, whether this platform can install it, this install, and the offer
        // made of it — or the reason there was none.
        Self.logCheck(read, installed: installed, source: source, offer: settled.log, highest: floor)
    }

    /// Turn one read of the feed into an offer (or a stated reason for none), and apply it.
    ///
    /// The offer is a function of two current facts only — the fresh document and the build running
    /// here. The one piece of history it respects is an explicit "Not now" for exactly this build,
    /// and that applies only to unsolicited checks.
    private func settle(_ read: FeedRead, installed: Int, manual: Bool) -> (outcome: CheckOutcome, log: String) {
        let shown = available

        // A document older than a card already on screen cannot retract it: the card is live
        // evidence of a document this session read, and a stale copy must not take a newer offer
        // away mid-read. This is the card-preserving half of what the stored floor used to do, and
        // it needs no persisted number — only what is actually on screen.
        func keepingNewerCard(than build: Int, because reason: String) -> (outcome: CheckOutcome, log: String)? {
            guard let shown, shown.build > build else { return nil }
            return (.offered(shown), "\(shown.build) (\(shown.version)) kept (\(reason))")
        }

        guard let found = read.installable else {
            if let kept = keepingNewerCard(than: read.advertised?.build ?? 0, because: "no installable entry") {
                return kept
            }
            // Withdraw a stale card: there is no installable entry behind it any more.
            available = nil
            isPromptVisible = false
            if let advertised = read.advertised {
                return (.notInstallable(advertised: advertised.build),
                        "none (newest \(advertised.build) is not installable here)")
            }
            return (.unreachable, "none (no document read)")
        }

        guard found.build > installed else {
            if let kept = keepingNewerCard(than: found.build, because: "document at \(found.build)") {
                return kept
            }
            // A document whose newest installable build is the running one or older: genuinely
            // current, and the only shape that may be reported as such.
            available = nil
            isPromptVisible = false
            return (.upToDate(newest: found.build, installed: installed),
                    "none (installed \(installed))")
        }

        // Unsolicited: a build the user already declined stays declined until a newer one appears.
        // Manual: the request was "tell me", so the skip does not apply.
        if !manual, found.build == skippedBuild {
            available = nil
            isPromptVisible = false
            return (.declined(build: found.build),
                    "none (skipped \(found.build))")
        }

        available = found
        rememberOffered(found.build)
        // The card is shown by whoever asked: a manual check is made from inside the Settings
        // sheet, so it must be presented *there*, over the sheet the user is looking at.
        promptHost = manual ? .settings : .root
        isPromptVisible = true
        return (.offered(found), "\(found.build) (\(found.version))")
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
        for url in Self.feedURLs {
            do {
                let fetched = try await fetch(url)
                let read = FeedRead(url: url, state: fetched.state, status: fetched.status,
                                    age: fetched.age, advertised: nil, installable: nil)
                guard let update = Self.update(in: fetched.data) else {
                    last = read
                    Self.note("update: \(url.absoluteString) answered \(fetched.state.rawValue) "
                              + "but carried no parsable entry")
                    continue
                }
                // The document's newest entry is the candidate. Comfortably: `update(in:)` reduces
                // with `max`, so an intermediate version is never what comes back.
                last = read.with(advertised: update, installable: nil)
                // An entry this platform cannot install is not an update. The mac feed names a
                // `.dmg`; handing that to a phone opened a disk image in Safari, which is what
                // "it downloads the dmg instead of the ipa" was — the manifest, not the card.
                // (`update(in:)` has already preferred an installable entry when the document
                // carries one, so reaching this guard means the document has none to offer.)
                guard Self.isInstallable(update.url) else {
                    print("[updates] \(url.lastPathComponent) advertises "
                          + "\(update.url.lastPathComponent) — not installable here")
                    // In the update log too: a phone reading a `.dmg` entry is the shape that used
                    // to be reported as "no update" with no trace of which document said so.
                    Self.note("update: \(url.absoluteString) advertises "
                              + "\(update.url.lastPathComponent) — not installable here")
                    continue
                }
                last = last.with(advertised: update, installable: update)
                // Name the document that answered, in its own line: three sources can carry the
                // same build, and "which one did this phone read" has to be answerable from the log
                // without matching the one measurement line below against a URL.
                Self.note("update: answered by \(url.absoluteString) (\(fetched.state.rawValue))")
                return last
            } catch {
                last = FeedRead(url: url, state: .unreachable, status: nil, age: nil,
                                advertised: nil, installable: nil)
                print("[updates] \(url.lastPathComponent) unavailable: \(error.localizedDescription)")
                // The log has to name the attempt, or "the primary feed failed and the fallback
                // answered" reads as a single check that found nothing.
                Self.note("update: \(url.absoluteString) unavailable: \(error.localizedDescription)")
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

    /// The one decision line a check leaves before it fetches anything.
    ///
    /// Separate from `logCheck` on purpose: this one says *why* a check happened (or did not), the
    /// other says *what* the feed answered. A log with only the second kind is exactly how a launch
    /// that never asked looked healthy — one `offer=none` line from before a publish and silence
    /// after it.
    static func note(_ text: String) {
        ClientLog.note(text, level: .info, category: "update")
    }

    /// The one line a check leaves in the `update` log.
    ///
    /// It names the source that asked (launch, foreground or manual), the URL, what the transport
    /// did, the newest build the document advertised, the newest build this platform can install,
    /// the build running here, the stored floor (recorded, never a gate — a value above
    /// `advertised` here is the only evidence a refusal could ever have left), and the offer that
    /// came of it or the reason there was none. One line from a phone settles "did it ask, what did
    /// it read, and why did it say what it said" without another round trip.
    static func logCheck(_ read: FeedRead, installed: Int, source: String, offer: String, highest: Int) {
        let advertised = read.advertised.map { "\($0.build) (\($0.version))" } ?? "none"
        let installable = read.installable.map { String($0.build) } ?? "none"
        let status = read.status.map { String($0) } ?? "-"
        let age = read.age.map { String($0) } ?? "-"
        ClientLog.note("update: check(source=\(source)) "
                       + "\(read.url?.absoluteString ?? "no-url") "
                       + "state=\(read.state.rawValue) "
                       + "http=\(status) "
                       + "age=\(age) "
                       + "advertised=\(advertised) "
                       + "installable=\(installable) "
                       + "installed=\(installed) "
                       + "highest=\(highest) "
                       + "offer=\(offer)",
                       level: .info, category: "update")
    }

    /// Remember the build that was actually shown.
    ///
    /// A record, not a gate: the log prints it, and nothing refuses a document because of it. The
    /// guard keeps it monotonic even if a stale value is somehow written later.
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
            // The offer is the document's maximum build. Comfortably: reduced with `max`, so an
            // intermediate version is never what comes back.
            let newest = candidates.max(by: { $0.build < $1.build })
            #if os(iOS)
            // A document that carries an entry this platform can install is never disqualified by
            // its *newest* entry being something else: the release notes once made the newest row a
            // `.dmg` while an installable `.ipa` sat right below it, and refusing the whole document
            // for the row this phone cannot use turned a feed with an update into "no document at
            // all". The newest installable entry is the offer; only a document with no installable
            // entry at all falls through to `newest`, which `latestUpdate` then refuses.
            if let installable = candidates
                .filter({ Self.isInstallable($0.url) })
                .max(by: { $0.build < $1.build }) {
                return installable
            }
            #endif
            return newest
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
