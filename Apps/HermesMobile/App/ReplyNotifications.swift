import BackgroundTasks
import Combine
import Foundation
import HermesAppKit
import HermesKit
import UIKit
import UserNotifications

/// Banners and the app-icon badge on the phone.
///
/// iOS has no long-lived socket to hang a notification on: the moment the app leaves the
/// foreground the WebSocket is torn down, so "a reply arrived while you were elsewhere" cannot be
/// observed from inside the app. There are exactly two levers, and this file owns both:
///
/// 1. **While the app is running** — the bot-list sweep reports a reply, `AppModel` decides it
///    deserves a banner, and this posts it. If the app is *active* the banner is dropped: the row's
///    own badge is already on screen, and a notice over the app the user is looking at is noise.
/// 2. **While it is suspended** — `ReplyBackgroundRefresh` asks iOS for a background refresh, reads
///    the same previews endpoint over the bridge, and posts a local notification for each bot that
///    wrote something new. This is genuinely instant only when the app is alive; suspended, it runs
///    on iOS's schedule (typically tens of minutes), which is the honest ceiling for a sideloaded
///    build — true remote push needs an APNs entitlement a personal-team install cannot carry.
@MainActor
final class MobileReplyNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    static let shared = MobileReplyNotifier()

    /// Set by the shell: tapping a banner opens that bot.
    var onOpenBot: ((String) -> Void)?

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var deliveryError: String?

    private var askedOnce = false
    private let center = UNUserNotificationCenter.current()

    var isAllowed: Bool {
        authorization == .authorized || authorization == .provisional || authorization == .ephemeral
    }

    func requestAuthorizationIfNeeded() {
        guard !askedOnce else { return }
        askedOnce = true
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            Task { @MainActor in
                self?.refreshAuthorization()
                if let error {
                    self?.deliveryError = error.localizedDescription
                    ClientLog.note("notification authorization refused: \(error.localizedDescription)",
                                   level: .warning, category: "notifications")
                } else if !granted {
                    ClientLog.note("notifications turned off for this app in Settings",
                                   level: .warning, category: "notifications")
                }
            }
        }
    }

    func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in self?.authorization = settings.authorizationStatus }
        }
    }

    /// Post the banner for a reply the model has already judged worth one.
    ///
    /// Foreground delivery is deliberately dropped rather than queued: by the time the user puts
    /// the phone down that banner would be about a message they may have already read.
    func post(_ note: ReplyNotification) {
        guard UIApplication.shared.applicationState != .active else {
            updateBadge(note.badge)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = note.botName
        content.body = note.body
        content.sound = .default
        content.userInfo = ["botID": note.botID]
        let request = UNNotificationRequest(identifier: note.identity, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.deliveryError = error.localizedDescription
                ClientLog.note("notification post failed: \(error.localizedDescription)",
                               level: .error, category: "notifications")
            }
        }
        updateBadge(note.badge)
    }

    /// The app icon's number. Zero clears it; the policy has already clamped the ceiling.
    func updateBadge(_ count: Int) {
        center.setBadgeCount(max(0, count)) { error in
            guard let error else { return }
            ClientLog.note("app badge update failed: \(error.localizedDescription)",
                           level: .warning, category: "notifications")
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// A banner that reached the centre was already judged worth showing: `post(_:)` drops the
    /// foreground case before the request is ever added, so this only has to allow it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let botID = response.notification.request.content.userInfo["botID"] as? String
        Task { @MainActor in
            if let botID { self.onOpenBot?(botID) }
        }
        completionHandler()
    }
}

/// The suspended-app half: one background refresh that reads the bridge's previews feed and turns
/// whatever is new into local notifications.
///
/// Registration has to happen before `didFinishLaunching` returns, so the app's `init` calls
/// `register()`. Everything it needs is on disk — `HostStore` restores the paired host from
/// `UserDefaults` and the refresh token from the Keychain without any UI — which is what makes this
/// runnable when no window exists.
enum ReplyBackgroundRefresh {

    static let taskIdentifier = "dev.hermey.app.mobile.refresh"

    /// iOS treats this as a *hint*: it decides when (and whether) the refresh runs, and a refresh
    /// that takes too long is killed. Fifteen minutes is the earliest a request may fire.
    static let requestedInterval: TimeInterval = 15 * 60

    /// Never more than this many banners from one refresh. A morning of cron output should not
    /// arrive as nine separate notices.
    private static let bannersPerRefresh = 3

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let work = Task { await run() }
            refresh.expirationHandler = { work.cancel() }
            Task {
                let finished = await work.value
                refresh.setTaskCompleted(success: finished)
                schedule()
            }
        }
    }

    static func schedule(after interval: TimeInterval = requestedInterval) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: max(60, interval))
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // A simulator, or a device that has exhausted its background budget: the feature
            // degrades to "badge while running" and says so in the log rather than failing silently.
            ClientLog.note("background refresh not scheduled: \(error.localizedDescription)",
                           level: .warning, category: "notifications")
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    // MARK: One refresh

    private static func run() async -> Bool {
        let defaults = AppModel.defaults
        // The switch is the app's own, so a user who turned banners off is not woken by them.
        guard defaults.object(forKey: "hermey.notifications.enabled") as? Bool ?? true else { return true }

        let store = HostStore()
        guard let host = store.host, let token = store.refreshToken else { return false }

        do {
            let ticket = try await BotIconService.mintTicket(baseURL: host.baseURL,
                                                             deviceID: host.deviceID,
                                                             refreshToken: token)
            // What this device has read (`lastRead`) and what it has already announced
            // (`notified`) are two different facts: opening a chat moves the first, posting a
            // banner moves the second, and only the second is written from here.
            let readMarks = marks(host: host.host, prefix: "hermey.lastRead.")
            let announced = marks(host: host.host, prefix: notifiedPrefix)
            let muted = Set(defaults.stringArray(forKey: "hermey.notifications.muted.\(host.host)") ?? [])

            var request = URLRequest(url: host.baseURL.appendingPathComponent("v1/bots/previews"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(ticket)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["since": readMarks])

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                ClientLog.note("background refresh refused (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))",
                               level: .warning, category: "notifications")
                return false
            }

            let feed = BotPreviewFeed.decode(data)
            let badge = ReplyNotificationPolicy.badge(unread: feed.unread)
            let center = UNUserNotificationCenter.current()
            center.setBadgeCount(badge, withCompletionHandler: nil)

            // Only bots with a *mark* can be new: a bot this device has never opened seeds its
            // mark on first sight (the same rule the unread badge follows), so a fresh install
            // does not announce a week of history.
            var fresh: [ReplyNotification] = []
            var advanced: [String: Double] = [:]
            for (bot, preview) in feed.previews {
                guard !muted.contains(bot) else { continue }
                guard let timestamp = preview.timestamp, timestamp > 0 else { continue }
                guard let mark = readMarks[bot], timestamp > mark else { continue }
                guard timestamp > (announced[bot] ?? 0) else { continue }
                advanced[bot] = timestamp
                fresh.append(ReplyNotification(botID: bot,
                                               botName: ReplyNotificationPolicy.title(botName: nil, botID: bot),
                                               body: ReplyNotificationPolicy.body(preview.text),
                                               badge: badge,
                                               at: Date(timeIntervalSince1970: timestamp)))
            }

            guard !fresh.isEmpty else { return true }
            let ordered = fresh.sorted { $0.at > $1.at }
            for note in ordered.prefix(bannersPerRefresh) {
                post(note, center: center)
            }
            if ordered.count > bannersPerRefresh {
                let extra = ordered.count - bannersPerRefresh
                let summary = UNMutableNotificationContent()
                summary.title = "Hermey"
                summary.body = extra == 1 ? "One more bot replied." : "\(extra) more bots replied."
                summary.sound = .default
                center.add(UNNotificationRequest(identifier: "summary-\(Int(Date().timeIntervalSince1970))",
                                                 content: summary,
                                                 trigger: nil),
                           withCompletionHandler: nil)
            }

            persistNotified(host: host.host, marks: advanced)
            ClientLog.note("background refresh: \(fresh.count) new replies, badge \(badge)",
                           level: .info, category: "notifications")
            return true
        } catch {
            ClientLog.note("background refresh failed: \(error.localizedDescription)",
                           level: .warning, category: "notifications")
            return false
        }
    }

    private static func post(_ note: ReplyNotification, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = note.botName
        content.body = note.body
        content.sound = .default
        content.userInfo = ["botID": note.botID]
        center.add(UNNotificationRequest(identifier: note.identity, content: content, trigger: nil),
                   withCompletionHandler: nil)
    }

    // MARK: Stored marks

    private static let notifiedPrefix = "hermey.notified."

    /// The marks a sweep compares against: what this device has actually read (`hermey.lastRead.<host>`)
    /// and, separately, what it has already announced (`hermey.notified.<host>`).
    private static func marks(host: String, prefix: String) -> [String: Double] {
        AppModel.defaults.dictionary(forKey: prefix + host) as? [String: Double] ?? [:]
    }

    /// Advance the announced marks only. Reading a message is a user action; announcing it is not,
    /// so the same dict the unread badge uses is never written from here.
    private static func persistNotified(host: String, marks: [String: Double]) {
        guard !marks.isEmpty else { return }
        var stored = Self.marks(host: host, prefix: notifiedPrefix)
        for (bot, timestamp) in marks { stored[bot] = max(stored[bot] ?? 0, timestamp) }
        AppModel.defaults.set(stored, forKey: notifiedPrefix + host)
    }
}
