import XCTest
@testable import HermesKit

/// The one key rule both apps use for a reaction.
///
/// This is the piece that has to be *identical* on the Mac, the phone and the host: a key that
/// differs by one byte is a reaction nothing ever looks up. The host validates the message half
/// itself (`reactions.rs`), so the two implementations have to agree on what a message key is.
final class ReactionKeyTests: XCTestCase {
    func testTheStorageKeyIsLengthPrefixedAndUnchangedFromWhatBothAppsWrote() {
        let key = ReactionKey(host: "casa", bot: "cody", session: "20261123_101500_ab12cd",
                              message: "row:41")
        // 4:casa | 4:cody | 22:20261123_101500_ab12cd | 6:row:41
        XCTAssertEqual(key.storageKey, "4:casa4:cody22:20261123_101500_ab12cd6:row:41")
    }

    func testAnIdentifierHoldingASeparatorCannotCollide() {
        // The same four parts joined with a `-` would give one string for both of these.
        let first = ReactionKey(host: "a-b", bot: "c", session: "s", message: "row:1").storageKey
        let second = ReactionKey(host: "a", bot: "b-c", session: "s", message: "row:1").storageKey
        XCTAssertNotEqual(first, second)
    }

    func testTheMessageHalfIsWhatTheHostStores() {
        XCTAssertEqual(ReactionKey.message(rowID: 41, entryID: "r7"), "row:41")
        XCTAssertEqual(ReactionKey.message(rowID: nil, entryID: "r7"), "live:r7")
        XCTAssertEqual(ReactionKey(host: "h", bot: "b", session: "s", message: "row:41").wireMessage,
                       "row:41")
    }

    func testAPersistedRowAndALiveEntryAreDifferentMessages() {
        // The same numeric suffix is two different messages: one the host can address, one it
        // cannot yet. Treating them as one key would put a reaction on the wrong row.
        let live = ReactionKey(host: "h", bot: "b", session: "s",
                               message: ReactionKey.message(rowID: nil, entryID: "41")).storageKey
        let row = ReactionKey(host: "h", bot: "b", session: "s",
                              message: ReactionKey.message(rowID: 41, entryID: "41")).storageKey
        XCTAssertNotEqual(live, row)
    }

    func testOnlyTheTwoHostPrefixesAreAccepted() {
        for good in ["row:41", "row:0", "live:r12", "live:user-3", "live:tcall_abc.1"] {
            XCTAssertTrue(ReactionKey.isValidMessage(good), good)
        }
        for bad in ["", "41", "row:", "live:", "msg:41", "row:41\n", "row:with space",
                    "row:41/..", "ROW:41"] {
            XCTAssertFalse(ReactionKey.isValidMessage(bad), bad)
        }
    }

    func testTheFourPartsReadBackOutOfAStorageKey() {
        let key = ReactionKey(host: "casa", bot: "cody", session: "20261123_101500_ab12cd",
                              message: "row:41")
        let parsed = ReactionKey.parse(key.storageKey)
        XCTAssertEqual(parsed, key)
        // A string that is not a storage key is refused rather than mis-parsed — the import walks
        // whatever the device's document held, and a hand-edited value must not become a reaction.
        XCTAssertNil(ReactionKey.parse("4:casa4:cody"))
        XCTAssertNil(ReactionKey.parse("x:casa"))
        XCTAssertNil(ReactionKey.parse(""))
        // Four parts and then a byte left over: not one key, so not silently two.
        XCTAssertNil(ReactionKey.parse("4:casa4:cody3:ses5:row:1x"))
        // A well-formed key is parsed whether or not the host would accept its message half; that
        // is a separate question (`isValidMessage`), and the import asks both.
        XCTAssertEqual(ReactionKey.parse("4:casa4:cody3:ses5:row:1")?.message, "row:1")
    }

    func testTheLocalDocumentIsPerConversationAndIsWhatBothAppsUsedToWrite() {
        let suite = "reaction-key-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ReactionLocalStore(defaults: defaults, key: "mobile.messageReactions.v1")
        let key = ReactionKey(host: "casa", bot: "cody", session: "s1", message: "row:1")
        store.set("👍", for: key.storageKey)

        // Read back through the JSON document, exactly as `@AppStorage` held it.
        let raw = defaults.string(forKey: "mobile.messageReactions.v1") ?? ""
        XCTAssertTrue(raw.contains("row:1"), raw)
        XCTAssertEqual(store.emoji(for: key.storageKey), "👍")
        XCTAssertEqual(store.entries(forConversation:
            ReactionKey.conversationPrefix(host: "casa", bot: "cody", session: "s1")).count, 1)
        XCTAssertTrue(store.entries(forConversation:
            ReactionKey.conversationPrefix(host: "casa", bot: "cody", session: "s2")).isEmpty)

        store.set(nil, for: key.storageKey)
        XCTAssertNil(store.emoji(for: key.storageKey))
    }
}
