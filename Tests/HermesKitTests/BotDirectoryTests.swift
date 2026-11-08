import Foundation
import XCTest
@testable import HermesKit

/// Multi-bot behaviour: one gateway, many Hermes profiles.
///
/// The measured facts these tests pin (deployed host, over TLS):
/// - `profiles.list {}` answers `{"profiles":[…], "bot_mode_protocol":…, "install_id":…}`;
/// - `session.list` needs `include_hidden: true` or a normal profile answers 0 rows
///   (`assistant` 0 → 1), and takes `profile: "<name>"` to scope to one bot
///   (`chief` 5, `analyst` 2, `ops` 1 at `limit: 5`).
///
/// The failure they exist to prevent is *mixing*: bot A's rows rendered under bot B's name.
final class BotDirectoryTests: XCTestCase {

    private func makeClient(_ fake: FakeGateway) -> GatewayClient {
        GatewayClient(makeTransport: { fake.bridge() }, timeouts: .testing, reconnect: .disabled)
    }

    /// A body shaped like the real one, including an entry the client must survive: one that names
    /// itself `profile` instead of `name`, one that is a bare string, and the host-level fields.
    private static let measuredProfiles: JSONValue = .object([
        "profiles": .array([
            .object(["name": .string("default"), "is_default": .bool(true)]),
            .object(["name": .string("analyst")]),
            .object(["profile": .string("night-ops")]),
            .string("charlie"),
            .object(["unexpected": .string("ignored")]),
        ]),
        "bot_mode_protocol": .int(2),
        "install_id": .string("install-abc123"),
    ])

    // MARK: profiles.list

    func testListBotsDecodesTheDirectoryInTheHostsOrder() async throws {
        let fake = FakeGateway()
        await fake.setResult(Self.measuredProfiles, for: "profiles.list")
        let client = makeClient(fake)
        try await client.connect()

        let bots = try await client.listBots()

        XCTAssertEqual(bots.map(\.id), ["default", "analyst", "night-ops", "charlie"],
                       "the id is the wire value `profile` takes; an entry without a name is skipped, not fatal")
        XCTAssertEqual(bots.map(\.name), ["default", "analyst", "night-ops", "charlie"])
        XCTAssertEqual(bots.map(\.displayName), ["default", "analyst", "night-ops", "charlie"],
                       "no label on the wire means the profile name is the label")

        let params = await fake.params(method: "profiles.list")
        XCTAssertEqual(params, JSONValue.object([:]), "profiles.list takes no parameters")

        XCTAssertEqual(bots.first?.avatarInitials, "D")
        XCTAssertEqual(bots[3].avatarInitials, "S")
    }

    func testBotFallsBackToTheProfileNameWhenNoDisplayLabelIsSent() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object([
            "profiles": .array([
                .object(["name": .string("assistant"), "display_name": .string("Assistant (work)")]),
                .object(["name": .string("ops")]),
                .object(["name": .string("delta"), "label": .string("Delta")]),
            ]),
        ]), for: "profiles.list")
        let client = makeClient(fake)
        try await client.connect()

        let bots = try await client.listBots()
        XCTAssertEqual(bots.map(\.id), ["assistant", "ops", "delta"], "a label never leaks into the id")
        XCTAssertEqual(bots.map(\.displayName), ["Assistant (work)", "ops", "Delta"])
        XCTAssertEqual(bots[1].label, "ops", "an unlabelled bot is still labelled by its name")
    }

    func testBotInitialsSurviveHyphenatedProfileNames() {
        XCTAssertEqual(Bot(id: "night-ops").avatarInitials, "NO")
        XCTAssertEqual(Bot(id: "assistant").avatarInitials, "C")
        XCTAssertEqual(Bot(id: "c").avatarInitials, "C")
    }

    func testListBotsRejectsAReplyWithoutAProfilesArray() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object(["profiles": .string("nope")]), for: "profiles.list")
        let client = makeClient(fake)
        try await client.connect()

        do {
            _ = try await client.listBots()
            XCTFail("a reply with no profile list is malformed, not an empty directory")
        } catch let error as GatewayError {
            XCTAssertEqual(error, .malformedResponse(method: "profiles.list"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testListBotsSurfacesAnOlderBackendsUnknownMethodInsteadOfNoBots() async throws {
        let fake = FakeGateway()
        await fake.setError(RPCError(code: -32601, message: "unknown method: profiles.list"),
                            for: "profiles.list")
        let client = makeClient(fake)
        try await client.connect()

        do {
            let bots = try await client.listBots()
            XCTFail("version skew must not look like 'this host has no bots': \(bots)")
        } catch let error as GatewayError {
            XCTAssertEqual(error.rpcError?.code, -32601)
            XCTAssertTrue(error.message.contains("profiles.list"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAnEmptyDirectoryIsAnAnswerNotAnError() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object(["profiles": .array([])]), for: "profiles.list")
        let client = makeClient(fake)
        try await client.connect()

        let bots = try await client.listBots()
        XCTAssertTrue(bots.isEmpty)
    }

    // MARK: session.list scoping

    func testListSessionsSendsIncludeHiddenAndTheProfile() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()

        _ = try await client.listSessions(limit: 5, profile: "chief", includeHidden: true)

        let params = await fake.params(method: "session.list")
        XCTAssertEqual(params, JSONValue.object([
            "limit": .int(5),
            "include_hidden": .bool(true),
            "profile": .string("chief"),
        ]), "the exact map: without include_hidden a normal profile answers 0 rows")
    }

    /// The default path is a bots surface too: a caller that forgets the new arguments must still
    /// get hidden sessions, because dropping them reads as "this bot is empty".
    func testTheSingleArgumentCallStillAsksForHiddenSessions() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()

        _ = try await client.listSessions(limit: 3)

        let params = await fake.params(method: "session.list")
        XCTAssertEqual(params?["include_hidden"]?.boolValue, true)
        XCTAssertNil(params?["profile"], "no bot selected means the host's own default profile")
    }

    func testExplicitlyExcludingHiddenSessionsIsStillPossible() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()

        _ = try await client.listSessions(limit: 3, profile: "assistant", includeHidden: false)

        let params = await fake.params(method: "session.list")
        XCTAssertEqual(params?["include_hidden"]?.boolValue, false)
    }

    /// The one that matters: two bots, two lists, and no way for one to answer the other.
    func testEachBotsListComesFromItsOwnProfileAndNeverMixes() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object(["sessions": .array([
            .object(["id": .string("chief-1"), "title": .string("cron audit")]),
            .object(["id": .string("chief-2"), "title": .string("tailnet")]),
        ])]), for: "session.list", whenParam: "profile", equals: "chief")
        await fake.setResult(.object(["sessions": .array([
            .object(["id": .string("analyst-1"), "title": .string("studio notes")]),
        ])]), for: "session.list", whenParam: "profile", equals: "analyst")
        await fake.setResult(.object(["sessions": .array([])]),
                             for: "session.list", whenParam: "profile", equals: "ops")

        let client = makeClient(fake)
        try await client.connect()

        let chief = try await client.listSessions(limit: 5, profile: "chief", includeHidden: true)
        let analyst = try await client.listSessions(limit: 5, profile: "analyst", includeHidden: true)
        let ops = try await client.listSessions(limit: 5, profile: "ops", includeHidden: true)

        XCTAssertEqual(chief.map(\.id), ["chief-1", "chief-2"])
        XCTAssertEqual(analyst.map(\.id), ["analyst-1"])
        XCTAssertTrue(ops.isEmpty, "a bot with no sessions is empty, and that is not the same as unloaded")

        let sent = await fake.frames(method: "session.list").compactMap { $0["params"] }
        XCTAssertEqual(sent.map { $0["profile"]?.stringValue }, ["chief", "analyst", "ops"],
                       "each call carried the bot it was made for")
        XCTAssertEqual(sent.map { $0["include_hidden"]?.boolValue }, [true, true, true])
        XCTAssertFalse(chief.contains { $0.id.hasPrefix("analyst") })
        XCTAssertFalse(analyst.contains { $0.id.hasPrefix("chief") })
    }

    /// A slow answer for the bot the user just left must not overwrite the bot they are on.
    /// The protocol layer cannot enforce this — the model does, with a generation counter — but the
    /// client must at least never *reuse* one profile's body for another, which is the same bug one
    /// layer down.
    func testConcurrentListsForDifferentBotsResolveIndependently() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object(["sessions": .array([
            .object(["id": .string("chief-1"), "title": .string("cron audit")]),
        ])]), for: "session.list", whenParam: "profile", equals: "chief")
        await fake.setResult(.object(["sessions": .array([
            .object(["id": .string("analyst-1"), "title": .string("studio notes")]),
        ])]), for: "session.list", whenParam: "profile", equals: "analyst")
        let client = makeClient(fake)
        try await client.connect()

        async let chief = client.listSessions(limit: 5, profile: "chief", includeHidden: true)
        async let analyst = client.listSessions(limit: 5, profile: "analyst", includeHidden: true)
        let (chiefRows, analystRows) = try await (chief, analyst)

        XCTAssertEqual(chiefRows.map(\.id), ["chief-1"])
        XCTAssertEqual(analystRows.map(\.id), ["analyst-1"])
    }
}
