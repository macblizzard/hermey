#if canImport(Combine)
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// A group chat's badge, driven through the model rather than the view.
///
/// The three promises worth holding: a room this device has never opened is **seeded**, not badged
/// (its history is not news); only the *bots'* lines count (the owner's own message is not something
/// waiting for them); and reading a room clears its count, so a badge cannot outlive the visit.
@MainActor
final class AppModelRoomUnreadTests: XCTestCase {

    private func hostName(_ label: String) -> String {
        "test-room-\(label)-\(UUID().uuidString)"
    }

    private func readKey(_ host: String) -> String { "hermey.roomRead.\(host)" }

    /// The persisted mark, read the way the model writes it (`[String: Int]` through
    /// `UserDefaults`, which bridges to `NSNumber` on the way back).
    private func storedMark(_ host: String, _ room: String) -> Int? {
        (UserDefaults.standard.dictionary(forKey: readKey(host))?[room] as? NSNumber)?.intValue
    }

    private func room(_ id: String, latest: Int) -> RoomSummary {
        RoomSummary(id: id,
                    name: id,
                    members: [RoomMemberSummary(profile: "assistant",
                                                handle: "assistant",
                                                displayName: "Assistant")],
                    latestSeq: latest)
    }

    private func line(_ seq: Int, fromOwner: Bool) -> RoomMessage {
        RoomMessage(seq: seq,
                    eventID: "event-\(seq)",
                    speaker: fromOwner ? "you" : "assistant",
                    isOwner: fromOwner,
                    text: "line \(seq)")
    }

    func testFirstSightSeedsTheMarkInsteadOfBadgingHistory() async {
        let host = hostName("seed")
        defer { UserDefaults.standard.removeObject(forKey: readKey(host)) }
        let client = ScriptedHost(session: "s1")
        client.roomList = [room("r1", latest: 7)]
        client.roomLogs = ["r1": (1 ... 7).map { line($0, fromOwner: false) }]
        let model = AppModel(client: client, hostName: host)

        await model.refreshRooms()

        XCTAssertEqual(model.rooms.count, 1)
        XCTAssertEqual(model.roomUnreadCount("r1"), 0)
        XCTAssertFalse(model.hasUnreadRoom("r1"))
        // The mark exists now, at the newest line this device has seen.
        XCTAssertEqual(storedMark(host, "r1"), 7)
    }

    func testNewBotLinesAfterTheMarkAreCounted() async {
        let host = hostName("count")
        defer { UserDefaults.standard.removeObject(forKey: readKey(host)) }
        let client = ScriptedHost(session: "s1")
        client.roomList = [room("r1", latest: 2)]
        client.roomLogs = ["r1": [line(1, fromOwner: true), line(2, fromOwner: false)]]
        let model = AppModel(client: client, hostName: host)
        await model.refreshRooms()
        XCTAssertEqual(model.roomUnreadCount("r1"), 0)

        // Two bots answered while the list was elsewhere.
        client.roomLogs = ["r1": (1 ... 4).map { line($0, fromOwner: false) }]
        client.roomList = [room("r1", latest: 4)]
        await model.refreshRooms()

        XCTAssertEqual(model.roomUnreadCount("r1"), 2)
        XCTAssertTrue(model.hasUnreadRoom("r1"))
    }

    func testOnlyOwnerLinesDoNotBadge() async {
        let host = hostName("owner")
        defer { UserDefaults.standard.removeObject(forKey: readKey(host)) }
        let client = ScriptedHost(session: "s1")
        client.roomList = [room("r1", latest: 1)]
        client.roomLogs = ["r1": [line(1, fromOwner: false)]]
        let model = AppModel(client: client, hostName: host)
        await model.refreshRooms()

        // This device posted twice from another screen: nothing is waiting for it here.
        client.roomLogs = ["r1": [line(1, fromOwner: false), line(2, fromOwner: true), line(3, fromOwner: true)]]
        client.roomList = [room("r1", latest: 3)]
        await model.refreshRooms()

        XCTAssertEqual(model.roomUnreadCount("r1"), 0)
        // The mark still advanced past them, so they cannot be counted later.
        XCTAssertEqual(storedMark(host, "r1"), 3)
    }

    func testReadingTheRoomClearsItsCount() async {
        let host = hostName("read")
        defer { UserDefaults.standard.removeObject(forKey: readKey(host)) }
        let client = ScriptedHost(session: "s1")
        client.roomList = [room("r1", latest: 1)]
        client.roomLogs = ["r1": [line(1, fromOwner: false)]]
        let model = AppModel(client: client, hostName: host)
        await model.refreshRooms()

        client.roomLogs = ["r1": (1 ... 3).map { line($0, fromOwner: false) }]
        client.roomList = [room("r1", latest: 3)]
        await model.refreshRooms()
        XCTAssertEqual(model.roomUnreadCount("r1"), 2)

        model.openRoom(model.rooms[0])
        XCTAssertEqual(model.roomUnreadCount("r1"), 0)
        XCTAssertEqual(storedMark(host, "r1"), 3)
    }

    func testUnreadElsewhereCountsRoomsAndSkipsTheOpenBot() async {
        let host = hostName("elsewhere")
        defer { UserDefaults.standard.removeObject(forKey: readKey(host)) }
        let client = ScriptedHost(session: "s1")
        client.roomList = [room("r1", latest: 1)]
        client.roomLogs = ["r1": [line(1, fromOwner: false)]]
        let model = AppModel(client: client, hostName: host)
        await model.refreshRooms()

        client.roomLogs = ["r1": (1 ... 4).map { line($0, fromOwner: false) }]
        client.roomList = [room("r1", latest: 4)]
        await model.refreshRooms()

        // A room's lines are part of "what is waiting elsewhere" — it is a chat with bots in it.
        XCTAssertEqual(model.unreadElsewhere(excludingBot: nil), 3)
        XCTAssertEqual(model.unreadElsewhere(excludingBot: "assistant"), 3)
    }

    func testARoomThatDisappearsLosesItsBadge() async {
        let host = hostName("disband")
        defer { UserDefaults.standard.removeObject(forKey: readKey(host)) }
        let client = ScriptedHost(session: "s1")
        client.roomList = [room("r1", latest: 1)]
        client.roomLogs = ["r1": [line(1, fromOwner: false)]]
        let model = AppModel(client: client, hostName: host)
        await model.refreshRooms()

        client.roomLogs = ["r1": (1 ... 2).map { line($0, fromOwner: false) }]
        client.roomList = [room("r1", latest: 2)]
        await model.refreshRooms()
        XCTAssertEqual(model.roomUnreadCount("r1"), 1)

        client.roomList = []
        await model.refreshRooms()
        XCTAssertEqual(model.roomUnreadCount("r1"), 0)
    }
}
#endif
