import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// The pure half of reply notifications: who deserves a banner, what the badge reads, and what a
/// banner says. Runs on Linux in the scratch package, which is the only place these decisions can
/// be proven without a device.
final class ReplyNotificationPolicyTests: XCTestCase {

    func testDeliversForABotThatIsNotOnScreen() {
        XCTAssertTrue(ReplyNotificationPolicy.shouldDeliver(botID: "cody",
                                                            visibleBotID: nil,
                                                            enabled: true,
                                                            muted: []))
        XCTAssertTrue(ReplyNotificationPolicy.shouldDeliver(botID: "cody",
                                                            visibleBotID: "fino",
                                                            enabled: true,
                                                            muted: []))
    }

    func testDoesNotDeliverForTheBotOnScreen() {
        // "Not currently reading" is literal: the open transcript has already said it.
        XCTAssertFalse(ReplyNotificationPolicy.shouldDeliver(botID: "cody",
                                                             visibleBotID: "cody",
                                                             enabled: true,
                                                             muted: []))
    }

    func testDoesNotDeliverWhenTurnedOffOrQuieted() {
        XCTAssertFalse(ReplyNotificationPolicy.shouldDeliver(botID: "cody",
                                                             visibleBotID: nil,
                                                             enabled: false,
                                                             muted: []))
        XCTAssertFalse(ReplyNotificationPolicy.shouldDeliver(botID: "cody",
                                                             visibleBotID: nil,
                                                             enabled: true,
                                                             muted: ["cody"]))
        XCTAssertTrue(ReplyNotificationPolicy.shouldDeliver(botID: "cody",
                                                            visibleBotID: nil,
                                                            enabled: true,
                                                            muted: ["fino"]))
    }

    func testAnEmptyBotIDNeverNotifies() {
        XCTAssertFalse(ReplyNotificationPolicy.shouldDeliver(botID: "",
                                                             visibleBotID: nil,
                                                             enabled: true,
                                                             muted: []))
    }

    func testBadgeCountsBotsAndRoomsTogether() {
        XCTAssertEqual(ReplyNotificationPolicy.badge(unread: ["cody": 2, "fino": 1],
                                                     rooms: ["ops": 3]), 6)
        XCTAssertEqual(ReplyNotificationPolicy.badge(unread: [:]), 0)
        XCTAssertEqual(ReplyNotificationPolicy.badge(unread: ["cody": 0], rooms: ["ops": 0]), 0)
    }

    func testBadgeIsClampedToTheCeiling() {
        XCTAssertEqual(ReplyNotificationPolicy.badge(unread: ["cody": 140]), 99)
        XCTAssertEqual(ReplyNotificationPolicy.badge(unread: ["cody": 60], rooms: ["ops": 60]), 99)
        // A negative from a host that miscounted is not allowed to lower the total.
        XCTAssertEqual(ReplyNotificationPolicy.badge(unread: ["cody": 3, "fino": -5]), 3)
    }

    func testBodyIsTheFirstLineOnly() {
        XCTAssertEqual(ReplyNotificationPolicy.body("Deploy is green\nsecond line"), "Deploy is green")
    }

    func testBodyFallsBackWhenThereIsNothingToSay() {
        XCTAssertEqual(ReplyNotificationPolicy.body(nil), "New reply")
        XCTAssertEqual(ReplyNotificationPolicy.body("   \n\n"), "New reply")
        XCTAssertEqual(ReplyNotificationPolicy.body("", fallback: "Done"), "Done")
    }

    func testBodyIsClippedAtTheSharedLimit() {
        let long = String(repeating: "a", count: ReplyNotificationPolicy.bodyLimit + 40)
        let clipped = ReplyNotificationPolicy.body(long)
        // The ellipsis is one character on top of the limit; both platforms must agree on where
        // the sentence stops, or the same reply reads differently on the Mac and the phone.
        XCTAssertEqual(clipped.count, ReplyNotificationPolicy.bodyLimit + 1)
        XCTAssertTrue(clipped.hasSuffix("…"))
    }

    func testTitlePrefersTheDisplayNameAndCapitalisesAnID() {
        XCTAssertEqual(ReplyNotificationPolicy.title(botName: "Cody", botID: "cody"), "Cody")
        XCTAssertEqual(ReplyNotificationPolicy.title(botName: "  ", botID: "fino"), "Fino")
        XCTAssertEqual(ReplyNotificationPolicy.title(botName: nil, botID: ""), "Hermes")
    }

    func testIdentityIsOneHostMessageNotOneArrival() throws {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let first = ReplyNotification(botID: "cody", botName: "Cody", body: "a", badge: 1, at: at)
        let again = ReplyNotification(botID: "cody", botName: "Cody", body: "a", badge: 1, at: at)
        let later = ReplyNotification(botID: "cody", botName: "Cody", body: "b", badge: 2,
                                      at: at.addingTimeInterval(60))
        XCTAssertEqual(first.identity, again.identity)
        XCTAssertNotEqual(first.identity, later.identity)
    }
}

/// The wiring: a reply on a bot that is not on screen reaches the sink exactly once, and the
/// plumbing respects the switches the user was given.
///
/// `AppModel` is `#if canImport(Combine)`, so these cases run on macOS (the CI package job) and
/// not in the Linux container — the policy cases above are the half that runs here.
#if canImport(Combine)
@MainActor
final class AppModelReplyNotificationTests: XCTestCase {

    private func hostName(_ label: String) -> String {
        "test-notify-\(label)-\(UUID().uuidString)"
    }

    private func cleanup(_ host: String) {
        for key in ["hermey.lastRead.", "hermey.notifications.muted."] {
            UserDefaults.standard.removeObject(forKey: key + host)
        }
        UserDefaults.standard.removeObject(forKey: "hermey.notifications.enabled")
    }

    func testAReplyOnAnotherBotReachesTheSinkOnce() async throws {
        let host = hostName("once")
        defer { cleanup(host) }
        let client = ScriptedHost(session: "20260101_000001_once")
        client.bots = [Bot(id: "cody", displayName: "Cody"), Bot(id: "fino", displayName: "Fino")]
        let model = AppModel(client: client, hostName: host)

        // A mark from yesterday: the reply below is newer than anything this device has seen.
        model.markRead("cody", at: Date(timeIntervalSince1970: 1_000))
        await model.loadBots()

        var received: [ReplyNotification] = []
        model.replyNotificationSink = { received.append($0) }

        client.previewFeed = BotPreviewFeed(
            previews: ["cody": BotConversationPreview(text: "Deploy is green.\nsecond",
                                                      role: "assistant",
                                                      timestamp: 2_000),
                       "fino": BotConversationPreview(text: "old news",
                                                      role: "assistant",
                                                      timestamp: 900)],
            unread: ["cody": 2])

        await model.loadBotPreviews()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.botID, "cody")
        XCTAssertEqual(received.first?.botName, "Cody")
        XCTAssertEqual(received.first?.body, "Deploy is green.")
        XCTAssertEqual(received.first?.badge, 2)

        // The same reply, swept again: the identity is the host's timestamp, so no second buzz.
        await model.loadBotPreviews()
        XCTAssertEqual(received.count, 1)
    }

    func testTheBotOnScreenIsNeverNotified() async throws {
        let host = hostName("visible")
        defer { cleanup(host) }
        let client = ScriptedHost(session: "20260101_000002_visible")
        client.bots = [Bot(id: "cody", displayName: "Cody")]
        let model = AppModel(client: client, hostName: host)
        model.markRead("cody", at: Date(timeIntervalSince1970: 1_000))
        await model.loadBots()
        // Opening the conversation is what "currently reading" means.
        model.setVisibleBot("cody")

        var received: [ReplyNotification] = []
        model.replyNotificationSink = { received.append($0) }
        client.previewFeed = BotPreviewFeed(
            previews: ["cody": BotConversationPreview(text: "hello", role: "assistant", timestamp: 2_000)],
            unread: ["cody": 1])

        await model.loadBotPreviews()
        XCTAssertTrue(received.isEmpty)
    }

    func testQuietingABotAndTurningNotificationsOffBothSilence() async throws {
        let host = hostName("switches")
        defer { cleanup(host) }
        let client = ScriptedHost(session: "20260101_000003_switches")
        client.bots = [Bot(id: "cody", displayName: "Cody")]
        let model = AppModel(client: client, hostName: host)
        model.markRead("cody", at: Date(timeIntervalSince1970: 1_000))
        await model.loadBots()

        var received: [ReplyNotification] = []
        model.replyNotificationSink = { received.append($0) }
        client.previewFeed = BotPreviewFeed(
            previews: ["cody": BotConversationPreview(text: "hello", role: "assistant", timestamp: 2_000)])

        model.toggleNotificationMute("cody")
        XCTAssertTrue(model.isNotificationMuted("cody"))
        await model.loadBotPreviews()
        XCTAssertTrue(received.isEmpty)

        model.toggleNotificationMute("cody")
        model.setReplyNotifications(enabled: false)
        XCTAssertFalse(model.replyNotificationsEnabled)
        await model.loadBotPreviews()
        XCTAssertTrue(received.isEmpty)

        // Back on, and the same reply is still waiting: it earns its banner now.
        model.setReplyNotifications(enabled: true)
        await model.loadBotPreviews()
        XCTAssertEqual(received.count, 1)
    }
}
#endif
