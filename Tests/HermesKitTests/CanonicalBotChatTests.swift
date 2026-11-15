import Foundation
import XCTest
@testable import HermesKit

/// The decision only — no socket, no bridge, no UserDefaults.
///
/// `AppModel.endlessSession(for:)` carries the plan out; these cases pin what the plan may be. The
/// property that matters: a bot whose conversation is the host's canonical `Bot Chat` must open
/// *that* session, because it is the same conversation Desktop, the TUI, cron delivery, bot-to-bot
/// messages and the official app all use. A Hermey-only id is a conversation nobody else can see.
final class CanonicalBotChatTests: XCTestCase {

    private let canonical = "20261106_165329_293f4b"
    private let legacy = "20260101_120000_aaaaaa"
    private let local = "20260102_090000_bbbbbb"

    // MARK: The host's answer wins

    func testTheHostsCanonicalChatIsOpenedWhateverThePointerSays() {
        let plan = CanonicalBotChat.plan(host: .canonical(canonical), legacy: legacy, local: local)
        XCTAssertEqual(plan.step, .resume(canonical),
                       "the pointer is a cache now: it must not win over the host's registry row")
        XCTAssertTrue(plan.publishCache, "the pointer should be repaired to agree with the host")
    }

    func testTheHostsCanonicalChatIsOpenedWithNoPointerAtAll() {
        let plan = CanonicalBotChat.plan(host: .canonical(canonical), legacy: nil, local: nil)
        XCTAssertEqual(plan.step, .resume(canonical))
    }

    func testAnUnusableHostIdFallsThroughInsteadOfResumingGarbage() {
        let plan = CanonicalBotChat.plan(host: .canonical("not/a/session"), legacy: legacy, local: nil)
        XCTAssertEqual(plan.step, .adopt(legacy),
                       "an id resume would reject is the same as no answer — adopt what exists")
    }

    // MARK: Adoption — the user's history becomes the shared chat

    func testAnExistingPointerIsAdoptedNotReplaced() {
        let plan = CanonicalBotChat.plan(host: .absent, legacy: legacy, local: local)
        XCTAssertEqual(plan.step, .adopt(legacy),
                       "the bridge's id is at least shared with the other device, so it wins here")
        XCTAssertTrue(plan.publishCache)
    }

    func testADeviceOnlyConversationIsAdoptedToo() {
        let plan = CanonicalBotChat.plan(host: .absent, legacy: nil, local: local)
        XCTAssertEqual(plan.step, .adopt(local),
                       "renaming this one keeps the history the user already has")
    }

    func testNothingAnywhereMeansCreate() {
        let plan = CanonicalBotChat.plan(host: .absent, legacy: nil, local: nil)
        XCTAssertEqual(plan.step, .create)
        XCTAssertTrue(plan.publishCache,
                      "a conversation this device minted cannot already be the answer")
    }

    func testAnUnusablePointerIsIgnored() {
        let plan = CanonicalBotChat.plan(host: .absent, legacy: "  ", local: local)
        XCTAssertEqual(plan.step, .adopt(local))
    }

    // MARK: The host could not be asked

    func testAnUnreachableHostOpensTheCachedConversationAndPublishesNothing() {
        let plan = CanonicalBotChat.plan(host: .unavailable, legacy: nil, local: local)
        XCTAssertEqual(plan.step, .resume(local))
        XCTAssertFalse(plan.publishCache,
                       "a pointer we could not read may exist and must not be clobbered")
    }

    func testAnUnreachableHostStillUsesTheBridgePointer() {
        let plan = CanonicalBotChat.plan(host: .unavailable, legacy: legacy, local: nil)
        XCTAssertEqual(plan.step, .resume(legacy))
        XCTAssertFalse(plan.publishCache)
    }

    func testAnUnreachableHostWithNothingKnownCreates() {
        let plan = CanonicalBotChat.plan(host: .unavailable, legacy: nil, local: nil)
        XCTAssertEqual(plan.step, .create,
                       "refusing to open a chat because one read failed is worse than minting one")
        XCTAssertTrue(plan.publishCache)
    }

    // MARK: Ids and failures

    func testUsableIdAcceptsStoredKeysAndRefusesPaths() {
        XCTAssertEqual(CanonicalBotChat.usableID(canonical), canonical)
        XCTAssertNil(CanonicalBotChat.usableID(nil))
        XCTAssertNil(CanonicalBotChat.usableID(""))
        XCTAssertNil(CanonicalBotChat.usableID("../../etc/passwd"))
        XCTAssertNil(CanonicalBotChat.usableID(".hidden"))
        XCTAssertNil(CanonicalBotChat.usableID(String(repeating: "a", count: 129)))
    }

    func testTitleConflictIsRecognisedFromTheHostsOwnWording() {
        let conflict = GatewayError.rpc(RPCError(code: 4001,
                                                 message: "Title 'Bot Chat' is already in use by session 20260101_120000_aaaaaa"))
        let other = GatewayError.rpc(RPCError(code: 4001, message: "invalid params"))
        XCTAssertTrue(CanonicalBotChat.isTitleConflict(conflict))
        XCTAssertFalse(CanonicalBotChat.isTitleConflict(other))
        XCTAssertFalse(CanonicalBotChat.isTitleConflict(GatewayError.notConnected))
    }

    func testAnOldGatewayIsNotMistakenForAConflict() {
        let unsupported = GatewayError.rpc(RPCError(code: -32601, message: "unknown method"))
        XCTAssertTrue(CanonicalBotChat.isUnsupported(unsupported))
        XCTAssertFalse(CanonicalBotChat.isTitleConflict(unsupported))
    }

    // MARK: Decoding `profiles.list`

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func testTheLiveTipIsPreferredOverTheRegistryRow() throws {
        let body = try json("""
        {"profiles":[{"name":"ops","canonical_session":
          {"id":"root_row","resolved_id":"compression_tip","title":"Bot Chat"}}]}
        """)
        XCTAssertEqual(try GatewayPayloadDecoder.canonicalBotChatID(body, profile: "ops"),
                       "compression_tip",
                       "rotation compaction moves the title off the row that is live; resuming the "
                       + "registry row opens a conversation that stopped moving")
    }

    func testTheRegistryRowIsTheFallbackForAHostWithoutAResolvedId() throws {
        let body = try json("""
        {"profiles":[{"name":"ops","canonical_session":{"id":"root_row","title":"Bot Chat"}}]}
        """)
        XCTAssertEqual(try GatewayPayloadDecoder.canonicalBotChatID(body, profile: "ops"), "root_row")
    }

    func testABotWithNoBotChatDecodesAsAbsent() throws {
        let nullField = try json("""
        {"profiles":[{"name":"ops","canonical_session":null}]}
        """)
        XCTAssertNil(try GatewayPayloadDecoder.canonicalBotChatID(nullField, profile: "ops"))

        let missingField = try json("""
        {"profiles":[{"name":"ops","last_session":{"id":"x"}}]}
        """)
        XCTAssertNil(try GatewayPayloadDecoder.canonicalBotChatID(missingField, profile: "ops"))
    }

    func testAnotherProfilesRowIsNeverMistakenForThisOnes() throws {
        let body = try json("""
        {"profiles":[{"name":"other","canonical_session":{"resolved_id":"other_chat"}},
                     {"name":"ops","canonical_session":{"resolved_id":"ops_chat"}}]}
        """)
        XCTAssertEqual(try GatewayPayloadDecoder.canonicalBotChatID(body, profile: "ops"), "ops_chat")
        XCTAssertNil(try GatewayPayloadDecoder.canonicalBotChatID(body, profile: "unserved"))
    }

    func testABodyWithoutProfilesIsMalformedRatherThanEmpty() throws {
        let body = try json("""
        {"bot_mode_protocol":true}
        """)
        XCTAssertThrowsError(try GatewayPayloadDecoder.canonicalBotChatID(body, profile: "ops")) { error in
            guard case GatewayError.malformedResponse(let method) = error else {
                return XCTFail("a silent nil here reads as 'this bot has no Bot Chat', which mints a twin")
            }
            XCTAssertEqual(method, "profiles.list")
        }
    }
}
