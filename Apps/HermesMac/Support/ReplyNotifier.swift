import AppKit
import Combine
import Foundation
import HermesAppKit
import HermesKit
import UserNotifications

/// Banners and the Dock tile for a reply in a conversation that is not on screen.
///
/// macOS needs no server: the app keeps running while the user is in another app and the bot
/// list's previews sweep keeps reading the host, so a banner is posted the moment the reply is
/// known — `AppModel.raiseReplyNotification` decides *whether* it is worth one and this only
/// delivers it.
///
/// Two facts about this build matter here. It is **ad-hoc signed and outside the App Store**, so
/// `UNUserNotificationCenter` is the only notification API on offer (the deprecated
/// `NSUserNotification` has no delegates worth the name in a modern macOS) — and if the system
/// refuses to register the bundle, that refusal is written to `ClientLog` and shown in
/// Settings → Notifications instead of making the feature look silently broken.
/// The Dock badge is separate and always available: `NSApp.dockTile.badgeLabel` needs no
/// permission at all.
@MainActor
final class ReplyNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    static let shared = ReplyNotifier()

    /// Set by the shell: a tap on a banner is a request to read that bot.
    var onOpenBot: ((String) -> Void)?

    /// What Settings reports. `.notDetermined` means the prompt has not been answered.
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// Why the system would not take a notification, when it would not.
    @Published private(set) var deliveryError: String?

    private var askedOnce = false

    private var center: UNUserNotificationCenter? {
        // A bundle that LaunchServices has not registered answers nil, and that is a fact about
        // the install, not a crash: the Dock badge keeps working and Settings says so.
        UNUserNotificationCenter.current()
    }

    /// Ask once, on the first launch that has something to show. Called from the shell's `.task`,
    /// not from `applicationDidFinishLaunching`: the prompt lands on a window the user can see.
    func requestAuthorizationIfNeeded() {
        guard !askedOnce, let center else { return }
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
                    ClientLog.note("notifications turned off for this app in System Settings",
                                   level: .warning, category: "notifications")
                }
            }
        }
    }

    func refreshAuthorization() {
        center?.getNotificationSettings { [weak self] settings in
            Task { @MainActor in self?.authorization = settings.authorizationStatus }
        }
    }

    /// Post one banner. The identifier is the host message's identity, so a reply reported twice
    /// replaces its own notification instead of stacking a second one.
    func post(_ note: ReplyNotification) {
        guard let center else {
            deliveryError = "This build is not registered for notifications."
            return
        }
        let content = UNMutableNotificationContent()
        content.title = note.botName
        content.body = note.body
        content.sound = .default
        content.userInfo = ["botID": note.botID]
        // Not a thread: two bots replying at once are two separate things to read, and macOS
        // stacks them by thread identically — but a thread per *bot* would hide the second
        // bot's banner behind the first's group.
        let request = UNNotificationRequest(identifier: note.identity, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.deliveryError = error.localizedDescription
                ClientLog.note("notification post failed: \(error.localizedDescription)",
                               level: .error, category: "notifications")
            }
        }
    }

    /// The Dock tile. Zero clears it rather than showing `0`, and past 99 the system prints `99+`
    /// for us — `ReplyNotificationPolicy` already clamps the number.
    func updateBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: UNUserNotificationCenterDelegate

    /// A banner must appear even while this app is frontmost, because "not reading that bot" is
    /// exactly the case of the user typing in *another* conversation here.
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
