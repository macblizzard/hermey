import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - The bridge's pointer

/// Which stored session is *this bot's* one conversation, as the bridge knows it.
///
/// The apps used to answer that question from their own `UserDefaults`, one key per bot per
/// device, so the phone and the Mac minted two different sessions for one bot. The bridge now
/// owns the answer (`GET`/`PUT /v1/bots/{profile}/session`, device-authenticated like `/v1/devices`)
/// and this protocol is the only thing `GatewayClient` needs from it.
///
/// Deliberately tiny and transport-shaped: the decision of *what to do* with the answer lives in
/// `EndlessSessionPolicy`, and the HTTP leg in `BridgeBotSessionPointer`, so both are testable
/// without a socket and without a device.
/// The newest message of a bot's conversation, as the bridge reads it off the host.
///
/// The gateway's own `session.list` preview is the *first* user message of a session (a title
/// stand-in), so a bot row built from it repeats what was asked days ago. This is the other end of
/// the conversation, whatever role it came from.
public struct BotConversationPreview: Hashable, Sendable {
    public let text: String
    /// `user` or `assistant`; the host stores nothing else for a message a list row should show.
    public let role: String
    public let timestamp: Double?

    public init(text: String, role: String, timestamp: Double? = nil) {
        self.text = text
        self.role = role
        self.timestamp = timestamp
    }
}

/// One round trip's worth of bot-list state: every row's third line, and how much each bot said
/// after this device last looked at it.
///
/// The two travel together on purpose. A count computed against a preview from a different moment
/// is the kind of number a user can catch being wrong — they open the bot, count two messages, and
/// the badge said three.
public struct BotPreviewFeed: Sendable, Equatable {
    public let previews: [String: BotConversationPreview]
    /// Profile name -> unread turns. Absent means zero, and zero is never sent.
    public let unread: [String: Int]

    public init(previews: [String: BotConversationPreview] = [:], unread: [String: Int] = [:]) {
        self.previews = previews
        self.unread = unread
    }

    /// Read either shape the bridge can answer with: `GET /v1/bots/previews` (previews only, older
    /// hosts) or `POST /v1/bots/previews` (previews + `unread`).
    public static func decode(_ data: Data) -> BotPreviewFeed {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return BotPreviewFeed()
        }
        var previews: [String: BotConversationPreview] = [:]
        if let rows = object["previews"] as? [String: Any] {
            for (profile, value) in rows {
                guard let row = value as? [String: Any],
                      let text = (row["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty
                else { continue }
                previews[profile] = BotConversationPreview(
                    text: text,
                    role: (row["role"] as? String) ?? "assistant",
                    timestamp: row["at"] as? Double
                )
            }
        }
        var unread: [String: Int] = [:]
        if let counts = object["unread"] as? [String: Any] {
            for (profile, value) in counts {
                // JSON may hand back Int, NSNumber or Double; anything that is not a positive
                // whole number means "nothing waiting".
                let raw = (value as? Int) ?? (value as? NSNumber)?.intValue ?? Int((value as? Double) ?? 0)
                if raw > 0 { unread[profile] = raw }
            }
        }
        return BotPreviewFeed(previews: previews, unread: unread)
    }
}

public protocol BotSessionPointerStore: Sendable {
    /// `GET /v1/bots/{profile}/session` — the shared stored session id, or `nil` when the bridge
    /// has none for this bot yet (unset, or a route the deployed bridge does not serve).
    func storedSessionID(for profile: String) async throws -> String?

    /// `PUT /v1/bots/{profile}/session` — publish `storedSessionID` so the other device adopts it.
    /// `nil` clears the pointer, which is what a reset means.
    func publish(storedSessionID: String?, for profile: String) async throws

    /// `GET /v1/bots/previews` — every bot's newest message, keyed by profile.
    ///
    /// Defaulted to empty so a pointer store that predates the route (or a test double) simply
    /// means "no previews from here", which sends the caller to the gateway's coarse fallback.
    func previews() async throws -> [String: BotConversationPreview]

    /// `POST /v1/bots/previews {"since": {profile: epoch}}` — the same rows, plus how many turns
    /// each bot wrote after the mark this device holds for it.
    ///
    /// Defaulted to the plain previews so a store that predates the route (or a test double) simply
    /// reports nothing unread instead of failing the list.
    func previews(since marks: [String: Double]) async throws -> BotPreviewFeed

    /// `POST /v1/bots/{profile}/purge` — delete a bot's profile on the host.
    ///
    /// The bridge archives the profile before it asks the host to remove it, so this is a real
    /// delete with a safety net, not a hide. Defaulted to a refusal: a store that predates the
    /// route must fail loudly rather than pretend a bot was deleted.
    func deleteBot(_ profile: String) async throws

    /// `POST /v1/bots/{profile}/state` — turn a bot off (its schedules paused) or back on.
    func setBotEnabled(_ profile: String, enabled: Bool) async throws

    /// `GET /v1/bots/disabled` — which bots are off, so the list can mark them without asking
    /// once per bot.
    func disabledBots() async throws -> Set<String>

    /// `GET`/`PUT /v1/bots/{profile}/model-settings` — the effort level and the aux/vision model.
    ///
    /// Two facts the catalogue cannot answer: how hard the model is asked to think (`agent.reasoning_effort`,
    /// where `""` is the provider's own default and `none` is thinking switched off), and which model looks
    /// at pictures when the bot's own cannot (`auxiliary.vision`, where provider `auto` inherits the main
    /// model). Both live in the profile's config on the host, so they are read and written per bot.
    func modelSettings(_ profile: String) async throws -> BotModelSettings

    /// `GET`/`PUT /v1/bots/approvals` — the approval mode applied to every bot profile.
    func approvalSettings() async throws -> ApprovalSettings
    func setApprovalMode(_ mode: ApprovalMode) async throws -> ApprovalSettings

    /// `POST /v1/pair/start` — mint a pairing invite for another device, authenticated as this paired
    /// device. Single-use, short-lived, the host's own code.
    func makePairingInvite() async throws -> PairingInvite
    func setModelSettings(_ profile: String, effort: String?,
                          visionProvider: String?, visionModel: String?) async throws -> BotModelSettings

    /// `GET /v1/bots/{profile}/routines` — this bot's schedules, soonest first.
    ///
    /// Defaulted to a refusal: a store that predates the route must say so, not draw "no routines"
    /// over a bot that runs four of them every night.
    func routines(_ profile: String) async throws -> [BotRoutine]

    /// `POST /v1/bots/{profile}/routines` — create one from the New Routine form.
    func createRoutine(_ profile: String, draft: RoutineDraft) async throws -> BotRoutine

    /// `POST /v1/bots/{profile}/routines/{jobID}/state` — pause one routine, or resume it.
    func setRoutinePaused(_ profile: String, jobID: String, paused: Bool) async throws

    /// `GET /v1/bots/{profile}/memory` — the two documents this bot carries into every turn.
    func memory(_ profile: String) async throws -> BotMemory

    /// `GET /v1/bots/{profile}/notes` — the owner's own note for this bot.
    func notes(_ profile: String) async throws -> BotNotes

    /// `PUT /v1/bots/{profile}/notes` — write the whole note back. Last write wins, on the host.
    func saveNotes(_ text: String, for profile: String) async throws -> BotNotes

    /// `GET /v1/bot-categories` — the owner's own groups, and which bot sits in which.
    ///
    /// Host state on purpose: the phone and the Mac must show the same groups, and a device that
    /// kept its own would disagree with the other one the moment either was used.
    func botCategories() async throws -> BotCategoryState

    /// `POST /v1/bot-categories` — a new group. A duplicate name is the host's refusal, not ours.
    func createBotCategory(name: String) async throws -> BotCategoryState

    /// `PATCH /v1/bot-categories/{id}` — rename a group.
    func renameBotCategory(id: String, name: String) async throws -> BotCategoryState

    /// `DELETE /v1/bot-categories/{id}` — drop a group. Its bots fall to Uncategorized; no bot is
    /// ever deleted with it.
    func deleteBotCategory(id: String) async throws -> BotCategoryState

    /// `PUT /v1/bots/{profile}/category` — put a bot in a group, or take it out with `nil`.
    func setBotCategory(profile: String, categoryID: String?) async throws -> BotCategoryState

    /// `PUT /v1/bot-categories/order` — the whole arrangement, not one swap.
    func reorderBotCategories(ids: [String]) async throws -> BotCategoryState

    /// `GET /v1/credentials/cards` — login cards waiting for the owner.
    func credentialCards() async throws -> [CredentialCard]
    /// `POST /v1/credentials/cards/{id}/answer` — what the owner typed; never echoed back.
    func answerCredentialCard(id: String, values: [String: String]) async throws
    /// `POST /v1/credentials/cards/{id}/cancel`
    func cancelCredentialCard(id: String) async throws

    /// `GET /v1/integrations` — connectable services and whether this host can connect them at all.
    func integrations() async throws -> IntegrationsState
    /// `POST /v1/integrations/{slug}/connect` — the hosted sign-in URL to open.
    func connectIntegration(slug: String, alias: String?) async throws -> String
    /// `POST /v1/integrations/{slug}/alias` — name an account so it can be told from another.
    func renameIntegration(slug: String, accountID: String, alias: String) async throws
    /// `POST /v1/integrations/{slug}/disconnect`
    func disconnectIntegration(slug: String, accountID: String?) async throws

    /// `GET /v1/search?q=…` — findings inside every bot's conversation, newest first.
    func searchTranscripts(_ query: String, limit: Int, offset: Int) async throws -> BotSearchPage

    /// `GET /v1/bot-transfers?between=a,b` — the exchanges between two bots, oldest first.
    func botTransfers(between first: String, and second: String, limit: Int) async throws -> [BotTransfer]

    /// `GET /v1/bot-defaults` — the soul a new bot starts from, and Hermes's own.
    func botDefaults() async throws -> BotDefaults

    /// `PUT /v1/bot-defaults/soul` — set it, or clear it with an empty text.
    func setDefaultSoul(_ text: String) async throws -> BotDefaults

    /// `GET /v1/backup` — every bot's config as one JSON document.
    func exportBackup() async throws -> Data

    func exportBackupZip() async throws -> Data

    func importPrompt() async throws -> String

    func importBackup(_ file: Data, mode: BotImportMode, dryRun: Bool) async throws -> BackupImportResult

    /// `POST /v1/backup/restore` — create what the document has and this host does not.
    func restoreBackup(_ document: Data) async throws -> BackupRestoreResult

    /// `POST /v1/push/register` — the relay endpoint this device's banners should go to.
    func registerPushRelay(_ url: String) async throws

    /// `POST /v1/push/presence` — which bot is on screen here.
    func reportPresence(bot: String?) async throws

    /// `POST /v1/push/test` — one banner, now.
    func sendTestPush() async throws

    /// `PUT /v1/push/icon/{bot}` — the face this bot's banners should show.
    func uploadPushIcon(bot: String, png: Data, sha256: String) async throws

    /// `GET /v1/rooms` — the group chats this host hosts.
    ///
    /// These four are protocol requirements, not free functions on an extension: a requirement that
    /// only exists in an extension is chosen statically, so a call through `any
    /// BotSessionPointerStore` would silently take the *default* and report "this host's bridge does
    /// not support" while the concrete store had a working implementation all along.
    func rooms() async throws -> [RoomSummary]

    /// `POST /v1/rooms` — open a room with 2–6 bots.
    func createRoom(name: String, members: [String]) async throws -> RoomSummary

    /// `GET /v1/rooms/{id}/log?since_seq=` — one page of a room's spoken log.
    func roomPage(_ roomID: String, since: Int?) async throws -> RoomPage

    /// `POST /v1/rooms/{id}/send` — one message; the bots it names answer.
    func sendRoomMessage(_ roomID: String, text: String) async throws

    /// The same message with files: the bridge stores them and puts their paths in the text.
    func sendRoomMessage(_ roomID: String, text: String, attachments: [RoomAttachment]) async throws

    /// `POST /v1/rooms/{id}/disband` — remove a group chat from every device.
    func disbandRoom(_ roomID: String) async throws

    /// `POST /v1/rooms/{id}/rename` — change the room's name on the host.
    func renameRoom(_ roomID: String, name: String) async throws
}

public extension BotSessionPointerStore {
    func deleteBot(_ profile: String) async throws { throw BotAdminUnavailable() }
    func setBotEnabled(_ profile: String, enabled: Bool) async throws { throw BotAdminUnavailable() }
    func disabledBots() async throws -> Set<String> { [] }
    func routines(_ profile: String) async throws -> [BotRoutine] { throw BotAdminUnavailable() }
    func modelSettings(_ profile: String) async throws -> BotModelSettings { throw BotAdminUnavailable() }
    func makePairingInvite() async throws -> PairingInvite { throw BotAdminUnavailable() }
    func approvalSettings() async throws -> ApprovalSettings { throw BotAdminUnavailable() }
    func setApprovalMode(_ mode: ApprovalMode) async throws -> ApprovalSettings {
        throw BotAdminUnavailable()
    }
    func setModelSettings(_ profile: String, effort: String?, visionProvider: String?,
                          visionModel: String?) async throws -> BotModelSettings {
        throw BotAdminUnavailable()
    }
    func createRoutine(_ profile: String, draft: RoutineDraft) async throws -> BotRoutine {
        throw BotAdminUnavailable()
    }
    func setRoutinePaused(_ profile: String, jobID: String, paused: Bool) async throws {
        throw BotAdminUnavailable()
    }
    func memory(_ profile: String) async throws -> BotMemory { throw BotAdminUnavailable() }
    func notes(_ profile: String) async throws -> BotNotes { throw BotAdminUnavailable() }
    func saveNotes(_ text: String, for profile: String) async throws -> BotNotes { throw BotAdminUnavailable() }
    func botCategories() async throws -> BotCategoryState { throw BotAdminUnavailable() }
    func createBotCategory(name: String) async throws -> BotCategoryState { throw BotAdminUnavailable() }
    func renameBotCategory(id: String, name: String) async throws -> BotCategoryState {
        throw BotAdminUnavailable()
    }
    func deleteBotCategory(id: String) async throws -> BotCategoryState { throw BotAdminUnavailable() }
    func reorderBotCategories(ids: [String]) async throws -> BotCategoryState {
        throw BotAdminUnavailable()
    }

    func credentialCards() async throws -> [CredentialCard] {
        throw BotAdminUnavailable()
    }

    func answerCredentialCard(id: String, values: [String: String]) async throws {
        throw BotAdminUnavailable()
    }

    func cancelCredentialCard(id: String) async throws {
        throw BotAdminUnavailable()
    }

    func integrations() async throws -> IntegrationsState {
        throw BotAdminUnavailable()
    }

    func connectIntegration(slug: String, alias: String?) async throws -> String {
        throw BotAdminUnavailable()
    }

    func integrationKeyFields(slug: String) async throws -> [IntegrationKeyField] {
        throw BotAdminUnavailable()
    }

    func connectIntegrationWithKey(slug: String, values: [String: String]) async throws {
        throw BotAdminUnavailable()
    }

    func renameIntegration(slug: String, accountID: String, alias: String) async throws {
        throw BotAdminUnavailable()
    }

    func disconnectIntegration(slug: String, accountID: String?) async throws {
        throw BotAdminUnavailable()
    }

    func setBotCategory(profile: String, categoryID: String?) async throws -> BotCategoryState {
        throw BotAdminUnavailable()
    }
    func searchTranscripts(_ query: String, limit: Int, offset: Int) async throws -> BotSearchPage {
        throw BotAdminUnavailable()
    }
    func botTransfers(between first: String, and second: String, limit: Int) async throws -> [BotTransfer] {
        throw BotAdminUnavailable()
    }
    func botDefaults() async throws -> BotDefaults { throw BotAdminUnavailable() }
    func setDefaultSoul(_ text: String) async throws -> BotDefaults { throw BotAdminUnavailable() }
    func exportBackup() async throws -> Data { throw BotAdminUnavailable() }
    func exportBackupZip() async throws -> Data { throw BotAdminUnavailable() }
    func importPrompt() async throws -> String { throw BotAdminUnavailable() }
    func importBackup(_ file: Data, mode: BotImportMode, dryRun: Bool) async throws -> BackupImportResult {
        throw BotAdminUnavailable()
    }
    func restoreBackup(_ document: Data) async throws -> BackupRestoreResult {
        throw BotAdminUnavailable()
    }
    func registerPushRelay(_ url: String) async throws { throw BotAdminUnavailable() }
    func reportPresence(bot: String?) async throws { throw BotAdminUnavailable() }
    func sendTestPush() async throws { throw BotAdminUnavailable() }
    func uploadPushIcon(bot: String, png: Data, sha256: String) async throws {
        throw BotAdminUnavailable()
    }
}

/// Thrown by a pointer store that has no admin routes (older bridge, test double).
public struct BotAdminUnavailable: LocalizedError {
    public init() {}
    public var errorDescription: String? {
        "This host's bridge does not support managing bots. Update the bridge on the host."
    }
}

extension BotSessionPointerStore {
    public func previews() async throws -> [String: BotConversationPreview] { [:] }

    public func previews(since marks: [String: Double]) async throws -> BotPreviewFeed {
        BotPreviewFeed(previews: try await previews())
    }
}

/// The real pointer: one HTTP request, one freshly minted single-use ticket.
///
/// Same credential shape as `VoiceService` and `BotIconService` on the app side — the caller
/// resolves *where* the bridge is and *what* ticket to present at request time, because a ticket
/// that went to a websocket (or to the previous request) is already spent and the paired host can
/// change while the client lives. Nothing is cached here, and nothing throws for a merely missing
/// value: "no pointer" is a normal answer, not an error.
public struct BridgeBotSessionPointer: BotSessionPointerStore {

    /// Everything one request needs, resolved per request.
    public typealias Endpoint = @Sendable () async throws -> (baseURL: URL, ticket: String)


enum Failure: Error, Equatable, LocalizedError {
        case noProfile
        case notHTTP
        case rejected(status: Int, detail: String?)
        case malformedResponse

        public var errorDescription: String? {
            switch self {
            case .noProfile: return "no bot was named for the shared conversation"
            case .notHTTP: return "the host's shared-conversation answer was not HTTP"
            case .rejected(let status, let detail):
                if let detail, !detail.isEmpty { return "the host refused the shared conversation (\(status)): \(detail)" }
                return "the host refused the shared conversation (\(status))"
            case .malformedResponse: return "the host's shared-conversation answer was not readable"
            }
        }
    }

    private let endpoint: Endpoint
    private let session: URLSession

    public init(endpoint: @escaping Endpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public func storedSessionID(for profile: String) async throws -> String? {
        // Resolved once: a ticket is single-use, so asking the provider twice would mint a second
        // ticket that no request ever spends.
        let endpoint = try await endpoint()
        let url = try Self.url(for: profile, base: endpoint.baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        // An older bridge has no such route; an unset pointer may also be spelled 404. Neither is
        // an error the user should ever see — it just means "ask the local cache instead".
        if http.statusCode == 404 || http.statusCode == 204 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        // A body this client cannot read is "no usable answer", not a failure: the pointer is an
        // optimisation, and opening a conversation must never depend on parsing it.
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // `stored_session_id` is the contract; `session_id` is tolerated because the bridge's own
        // session rows spell it that way and a mixed deployment must not fork the conversation.
        let raw = (object["stored_session_id"] as? String) ?? (object["session_id"] as? String)
        return EndlessSessionPolicy.storedID(raw)
    }

    public func publish(storedSessionID: String?, for profile: String) async throws {
        let endpoint = try await endpoint()
        let url = try Self.url(for: profile, base: endpoint.baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")
        // Explicit `null` clears the pointer; the key is always present so the bridge never has to
        // guess whether an absent field meant "leave it alone".
        let body: [String: Any] = ["stored_session_id": storedSessionID.map { $0 as Any } ?? NSNull()]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        if storedSessionID == nil, http.statusCode == 400 || http.statusCode == 422 {
            // The deployed route has no "clear": a null is rejected rather than deleting the row
            // ("never a delete" in `bot_sessions.py`). Nothing the caller can act on — the reset
            // device keeps a local tombstone — and a bridge that learns to clear simply answers 2xx.
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
    }

    /// `GET /v1/bots/previews` — one request for every bot's newest message.
    ///
    /// One call, not one per bot: the bridge reads each profile's message table directly, so the
    /// round trip is the only cost. A bridge without the route, or a body this client cannot read,
    /// answers empty rather than throwing — the bot list keeps its two lines instead of showing a
    /// failure over a decoration.
    public func previews() async throws -> [String: BotConversationPreview] {
        let endpoint = try await endpoint()
        let url = endpoint.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("bots")
            .appendingPathComponent("previews")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        if http.statusCode == 404 || http.statusCode == 204 { return [:] }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        return BotPreviewFeed.decode(data).previews
    }

    /// `POST /v1/bots/previews` — rows plus counts, in the one round trip the list already makes.
    ///
    /// An older bridge answers 404 to the POST: fall back to its `GET` so the rows still appear and
    /// the badges simply stay empty until the host is updated.
    public func previews(since marks: [String: Double]) async throws -> BotPreviewFeed {
        let endpoint = try await endpoint()
        let url = endpoint.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("bots")
            .appendingPathComponent("previews")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["since": marks])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        if http.statusCode == 404 || http.statusCode == 204 {
            return BotPreviewFeed(previews: try await previews())
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        return BotPreviewFeed.decode(data)
    }

    /// `POST /v1/bots/{profile}/purge`.
    ///
    /// A delete can take a while on the host (tombstone, multiplexer release, archive), so the
    /// request timeout is generous — and a timeout is reported as *unknown*, never as success.
    public func deleteBot(_ profile: String) async throws {
        let endpoint = try await endpoint()
        var url = endpoint.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("bots")
            .appendingPathComponent(profile)
            .appendingPathComponent("purge")
        url = try Self.encoded(url, profile: profile)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
    }

    /// `POST /v1/bots/{profile}/state`.
    public func setBotEnabled(_ profile: String, enabled: Bool) async throws {
        let endpoint = try await endpoint()
        var url = endpoint.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("bots")
            .appendingPathComponent(profile)
            .appendingPathComponent("state")
        url = try Self.encoded(url, profile: profile)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["enabled": enabled])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
    }

    /// `GET /v1/bots/disabled`.
    public func disabledBots() async throws -> Set<String> {
        let endpoint = try await endpoint()
        let url = endpoint.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("bots")
            .appendingPathComponent("disabled")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200..<300).contains(http.statusCode) else { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let names = object["disabled"] as? [String]
        else { return [] }
        return Set(names)
    }

    public func approvalSettings() async throws -> ApprovalSettings {
        let data = try await bridgeGET("v1/bots/approvals", timeout: 20)
        guard let settings = ApprovalSettings.decode(data) else { throw BotAdminUnavailable() }
        return settings
    }

    public func setApprovalMode(_ mode: ApprovalMode) async throws -> ApprovalSettings {
        let data = try await bridgePUT("v1/bots/approvals", body: ["mode": mode.rawValue], timeout: 60)
        guard let settings = ApprovalSettings.decode(data) else { throw BotAdminUnavailable() }
        return settings
    }

    /// `POST /v1/pair/start`, authenticated as this paired device. The mint is the host's own; the
    /// device's ticket is only the authorisation to ask for one on its behalf.
    public func makePairingInvite() async throws -> PairingInvite {
        let data = try await bridgePOST("v1/pair/start", body: [:], timeout: 15)
        guard let invite = PairingInvite.decode(data) else { throw BotAdminUnavailable() }
        return invite
    }

    /// `GET /v1/bots/{profile}/model-settings`.
    public func modelSettings(_ profile: String) async throws -> BotModelSettings {
        let name = try Self.pathComponent(profile)
        let data = try await bridgeGET("v1/bots/\(name)/model-settings")
        guard let settings = BotModelSettings.decode(data) else { throw BotAdminUnavailable() }
        return settings
    }

    /// `PUT /v1/bots/{profile}/model-settings` — only the fields given are sent, so one save cannot
    /// rewrite the knob beside it.
    public func setModelSettings(_ profile: String, effort: String?, visionProvider: String?,
                                 visionModel: String?) async throws -> BotModelSettings {
        let name = try Self.pathComponent(profile)
        var body: [String: Any] = [:]
        if let effort { body["effort"] = effort }
        if let visionProvider { body["vision_provider"] = visionProvider }
        if let visionModel { body["vision_model"] = visionModel }
        let data = try await bridgePUT("v1/bots/\(name)/model-settings", body: body)
        guard let settings = BotModelSettings.decode(data) else { throw BotAdminUnavailable() }
        return settings
    }

    /// `GET /v1/bots/{profile}/routines`.
    public func routines(_ profile: String) async throws -> [BotRoutine] {
        let name = try Self.pathComponent(profile)
        let data = try await bridgeGET("v1/bots/\(name)/routines", timeout: 20)
        return BotRoutine.decodeList(data)
    }

    /// `POST /v1/bots/{profile}/routines`.
    ///
    /// The draft is validated in the app as well, but this is the route that decides: a caller that
    /// builds its own body gets the same refusal, and the message is the one the form shows.
    public func createRoutine(_ profile: String, draft: RoutineDraft) async throws -> BotRoutine {
        let name = try Self.pathComponent(profile)
        let data = try await bridgePOST("v1/bots/\(name)/routines",
                                        body: draft.payload(), timeout: 60)
        guard let routine = BotRoutine.decodeOne(data) else {
            throw BotAdminUnavailable()
        }
        return routine
    }

    /// `POST /v1/bots/{profile}/routines/{jobID}/state`.
    ///
    /// The job id is host data used as a path segment, so it is escaped exactly like a profile name:
    /// an id that carried a slash would otherwise reshape the request.
    public func setRoutinePaused(_ profile: String, jobID: String, paused: Bool) async throws {
        let name = try Self.pathComponent(profile)
        let job = try Self.pathComponent(jobID)
        _ = try await bridgePOST("v1/bots/\(name)/routines/\(job)/state",
                                 body: ["paused": paused], timeout: 60)
    }

    /// `GET /v1/bots/{profile}/memory`.
    ///
    /// A document the host could not read is *not* an error here: the payload carries the reason per
    /// document, so one unreadable file does not hide the other. Only a payload that is not a memory
    /// answer at all fails.
    public func memory(_ profile: String) async throws -> BotMemory {
        let name = try Self.pathComponent(profile)
        let data = try await bridgeGET("v1/bots/\(name)/memory", timeout: 20)
        guard let memory = BotMemory.decode(data) else {
            throw Failure.rejected(status: 502, detail: "the host sent no memory")
        }
        return memory
    }

    public func notes(_ profile: String) async throws -> BotNotes {
        let name = try Self.pathComponent(profile)
        let data = try await bridgeGET("v1/bots/\(name)/notes", timeout: 20)
        guard let notes = decodeNotes(data) else {
            throw Failure.rejected(status: 502, detail: "the host sent no note")
        }
        return notes
    }

    public func saveNotes(_ text: String, for profile: String) async throws -> BotNotes {
        let name = try Self.pathComponent(profile)
        let data = try await bridgePUT("v1/bots/\(name)/notes",
                                       body: ["text": text], timeout: 20)
        guard let notes = decodeNotes(data) else {
            throw Failure.rejected(status: 502, detail: "the host sent no note")
        }
        return notes
    }

    public func registerPushRelay(_ url: String) async throws {
        _ = try await bridgePOST("v1/push/register", body: ["url": url], timeout: 20)
    }

    // MARK: Categories

    /// `GET /v1/bot-categories`.
    public func botCategories() async throws -> BotCategoryState {
        try BotCategoryState.decode(try await bridgeGET("v1/bot-categories", timeout: 20))
    }

    /// `POST /v1/bot-categories` — the host answers with the whole document, assignments included,
    /// so one call is enough to redraw the list.
    public func createBotCategory(name: String) async throws -> BotCategoryState {
        try BotCategoryState.decode(try await bridgePOST("v1/bot-categories",
                                                         body: ["name": name], timeout: 20))
    }

    public func renameBotCategory(id: String, name: String) async throws -> BotCategoryState {
        let category = try Self.pathComponent(id)
        return try BotCategoryState.decode(try await bridgePATCH("v1/bot-categories/\(category)",
                                                                 body: ["name": name], timeout: 20))
    }

    public func deleteBotCategory(id: String) async throws -> BotCategoryState {
        let category = try Self.pathComponent(id)
        return try BotCategoryState.decode(try await bridgeDELETE("v1/bot-categories/\(category)",
                                                                  timeout: 20))
    }

    /// `PUT /v1/bots/{profile}/category` — `category_id: null` means Uncategorized.
    public func setBotCategory(profile: String, categoryID: String?) async throws -> BotCategoryState {
        let name = try Self.pathComponent(profile)
        let body: [String: Any] = ["category_id": categoryID ?? NSNull()]
        return try BotCategoryState.decode(try await bridgePUT("v1/bots/\(name)/category",
                                                               body: body, timeout: 20))
    }

    /// `PUT /v1/bot-categories/order` — the arrangement, sent whole.
    ///
    /// Sending the arrangement rather than "move X up" is what keeps two devices from fighting: a
    /// swap computed from a document the other device already changed would move the wrong group,
    /// while an arrangement can only replace an arrangement.
    public func reorderBotCategories(ids: [String]) async throws -> BotCategoryState {
        try BotCategoryState.decode(try await bridgePUT("v1/bot-categories/order",
                                                        body: ["ids": ids], timeout: 20))
    }

    /// `GET /v1/credentials/cards` — the cards waiting for the owner, and nothing about their answers.
    public func credentialCards() async throws -> [CredentialCard] {
        try CredentialCard.list(from: try await bridgeGET("v1/credentials/cards", timeout: 20))
    }

    /// `POST /v1/credentials/cards/{id}/answer`. The reply says only that it was accepted.
    public func answerCredentialCard(id: String, values: [String: String]) async throws {
        let card = try Self.pathComponent(id)
        _ = try await bridgePOST("v1/credentials/cards/\(card)/answer",
                                 body: ["values": values], timeout: 20)
    }

    /// `POST /v1/credentials/cards/{id}/cancel`. Always obeyed.
    public func cancelCredentialCard(id: String) async throws {
        let card = try Self.pathComponent(id)
        _ = try await bridgePOST("v1/credentials/cards/\(card)/cancel", body: [:], timeout: 20)
    }

    /// `GET /v1/integrations`. The key that makes these work never travels — only the state does.
    public func integrations() async throws -> IntegrationsState {
        try IntegrationsState.from(try await bridgeGET("v1/integrations", timeout: 20))
    }

    /// `POST /v1/integrations/{slug}/connect`. Returns the hosted page the app opens in a browser.
    public func connectIntegration(slug: String, alias: String?) async throws -> String {
        let name = try Self.pathComponent(slug)
        var body: [String: Any] = [:]
        if let alias, !alias.isEmpty { body["alias"] = alias }
        let data = try await bridgePOST("v1/integrations/\(name)/connect", body: body, timeout: 40)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = root["url"] as? String, !url.isEmpty else {
            throw BotAdminUnavailable()
        }
        return url
    }

    /// `GET /v1/integrations/{slug}/key-fields` — what this service asks for, per Composio.
    public func integrationKeyFields(slug: String) async throws -> [IntegrationKeyField] {
        let name = try Self.pathComponent(slug)
        let data = try await bridgeGET("v1/integrations/\(name)/key-fields", timeout: 30)
        return try JSONDecoder().decode(IntegrationKeyFields.self, from: data).fields
    }

    /// `POST /v1/integrations/{slug}/key-connect` — the key goes to the host and on to Composio, nowhere else.
    ///
    /// Nothing comes back but an acknowledgement: the value is not echoed, so it cannot be read out of a reply or
    /// a log on the way home.
    public func connectIntegrationWithKey(slug: String, values: [String: String]) async throws {
        let name = try Self.pathComponent(slug)
        _ = try await bridgePOST("v1/integrations/\(name)/key-connect", body: ["values": values], timeout: 60)
    }

    /// `POST /v1/integrations/{slug}/alias` — give an account a name the owner recognises.
    public func renameIntegration(slug: String, accountID: String, alias: String) async throws {
        let name = try Self.pathComponent(slug)
        _ = try await bridgePOST("v1/integrations/\(name)/alias",
                                 body: ["account_id": accountID, "alias": alias], timeout: 30)
    }

    /// `POST /v1/integrations/{slug}/disconnect`. Named by account: with two Gmails, "gmail" is ambiguous.
    public func disconnectIntegration(slug: String, accountID: String?) async throws {
        let name = try Self.pathComponent(slug)
        var body: [String: Any] = [:]
        if let accountID { body["account_id"] = accountID }
        _ = try await bridgePOST("v1/integrations/\(name)/disconnect", body: body, timeout: 30)
    }

    /// `GET /v1/search` — a query goes on the wire percent-encoded: a phrase with a `&` or a `#`
    /// in it must search for that phrase, not reshape the request.
    public func searchTranscripts(_ query: String, limit: Int = 50, offset: Int = 0) async throws -> BotSearchPage {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let path = "v1/search?q=\(encoded)&limit=\(limit)&offset=\(offset)"
        return try BotSearchPage.decode(try await bridgeGET(path, timeout: 20))
    }

    /// `GET /v1/bot-transfers` — the pair's exchanges, both directions.
    public func botTransfers(between first: String, and second: String, limit: Int = 100) async throws -> [BotTransfer] {
        let a = try Self.pathComponent(first)
        let b = try Self.pathComponent(second)
        let data = try await bridgeGET("v1/bot-transfers?between=\(a),\(b)&limit=\(limit)", timeout: 20)
        return try BotTransfer.decodeList(data)
    }

    /// `GET /v1/bot-defaults`.
    public func botDefaults() async throws -> BotDefaults {
        try BotDefaults.decode(try await bridgeGET("v1/bot-defaults"))
    }

    /// `PUT /v1/bot-defaults/soul`. An empty text is the reset, and it is the same call on purpose.
    public func setDefaultSoul(_ text: String) async throws -> BotDefaults {
        try BotDefaults.decode(try await bridgePUT("v1/bot-defaults/soul", body: ["text": text]))
    }

    /// `GET /v1/backup` — handed back as bytes: the app writes it as a file, and does not need to
    /// understand the document to keep it.
    public func exportBackup() async throws -> Data {
        try await bridgeGET("v1/backup", timeout: 120)
    }

    /// `POST /v1/backup/restore` — the document goes back exactly as it came out of the file.
    public func exportBackupZip() async throws -> Data {
        try await bridgeGET("v1/backup.zip", timeout: 180)
    }

    /// The prompt lives on the host: the schema and this text change together, and an app built before a schema
    /// change should not hand out a prompt describing a format the host no longer reads.
    public func importPrompt() async throws -> String {
        let data = try await bridgeGET("v1/backup/import-prompt", timeout: 30)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prompt = object["prompt"] as? String, !prompt.isEmpty else {
            throw Failure.malformedResponse
        }
        return prompt
    }

    /// The file goes up as-is: a zip is not base64-inflated on the way, and the host reads what was saved.
    public func importBackup(_ file: Data, mode: BotImportMode, dryRun: Bool) async throws -> BackupImportResult {
        let query = "?mode=\(mode.rawValue)&dry_run=\(dryRun ? 1 : 0)"
        let data = try await bridgeSend("v1/backup/import\(query)", method: "POST", body: file,
                                         contentType: "application/zip", timeout: 300)
        return try BackupImportResult.decode(data)
    }

    public func restoreBackup(_ document: Data) async throws -> BackupRestoreResult {
        guard let object = try JSONSerialization.jsonObject(with: document) as? [String: Any] else {
            throw Failure.malformedResponse
        }
        return try BackupRestoreResult.decode(
            try await bridgePOST("v1/backup/restore", body: object, timeout: 180))
    }

    public func reportPresence(bot: String?) async throws {
        _ = try await bridgePOST("v1/push/presence", body: ["bot": bot ?? NSNull()], timeout: 15)
    }

    public func sendTestPush() async throws {
        _ = try await bridgePOST("v1/push/test", body: [:], timeout: 20)
    }

    public func uploadPushIcon(bot: String, png: Data, sha256: String) async throws {
        // Base64 in JSON rather than multipart: the bridge wants the bytes and a hash, and neither
        // side then needs an encoder it does not already have.
        _ = try await bridgePUT("v1/push/icon/\(bot)",
                                body: ["png": png.base64EncodedString(), "sha256": sha256],
                                timeout: 30)
    }

    private func decodeNotes(_ data: Data) -> BotNotes? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return BotNotes.decode(object)
    }

    /// One path segment from host data: non-empty, and never able to escape onto another path.
    private static func pathComponent(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: URLPath.componentAllowed)
        else { throw Failure.noProfile }
        return escaped
    }

    /// Percent-encode the profile segment: the path is built from a name the user typed.
    private static func encoded(_ url: URL, profile: String) throws -> URL {
        guard let escaped = profile.addingPercentEncoding(withAllowedCharacters: URLPath.componentAllowed),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw Failure.noProfile
        }
        // Replace the final two segments (`<profile>/<verb>`) with the escaped name.
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { throw Failure.noProfile }
        components.path = "/" + parts.dropLast(2).joined(separator: "/").split(separator: "/").joined(separator: "/")
            + "/" + escaped + "/" + (parts.last.map(String.init) ?? "")
        guard let rebuilt = components.url else { throw Failure.noProfile }
        return rebuilt
    }

    // MARK: Generic bridge calls

    /// One authenticated GET against the bridge. Internal, because the room routes live in their
    /// own file and a ticket must still be minted *after* the endpoint is resolved.
    func bridgeGET(_ path: String, timeout: TimeInterval = 20) async throws -> Data {
        let endpoint = try await endpoint()
        var request = URLRequest(url: Self.bridgeURL(endpoint.baseURL, path))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        return data
    }

    /// One authenticated PUT against the bridge, JSON in and JSON out. A note is *replaced*, so
    /// PUT rather than POST: the host takes the whole text and does not append.
    func bridgePUT(_ path: String, body: [String: Any], timeout: TimeInterval = 20) async throws -> Data {
        let endpoint = try await endpoint()
        var request = URLRequest(url: Self.bridgeURL(endpoint.baseURL, path))
        request.httpMethod = "PUT"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        return data
    }

    /// One authenticated POST against the bridge, JSON in and JSON out.
    /// POST a body that is not JSON — a zip, a picture — without wrapping it in a JSON envelope.
    func bridgeSend(_ path: String, method: String, body: Data, contentType: String,
                    timeout: TimeInterval = 60) async throws -> Data {
        let endpoint = try await endpoint()
        var request = URLRequest(url: Self.bridgeURL(endpoint.baseURL, path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        return data
    }

    func bridgePOST(_ path: String, body: [String: Any], timeout: TimeInterval = 60) async throws -> Data {
        let endpoint = try await endpoint()
        var request = URLRequest(url: Self.bridgeURL(endpoint.baseURL, path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        return data
    }

    /// One authenticated PATCH against the bridge, JSON in and JSON out. A rename is a partial
    /// update of one field, which is what PATCH is for.
    func bridgePATCH(_ path: String, body: [String: Any], timeout: TimeInterval = 20) async throws -> Data {
        let endpoint = try await endpoint()
        var request = URLRequest(url: Self.bridgeURL(endpoint.baseURL, path))
        request.httpMethod = "PATCH"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        return data
    }

    /// One authenticated DELETE. The host answers with the document it left behind, so the caller
    /// can redraw from the answer instead of guessing what a deletion did.
    func bridgeDELETE(_ path: String, timeout: TimeInterval = 20) async throws -> Data {
        let endpoint = try await endpoint()
        var request = URLRequest(url: Self.bridgeURL(endpoint.baseURL, path))
        request.httpMethod = "DELETE"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.ticket)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        return data
    }

    /// `/v1/rooms/<id>/log?since_seq=12` appended to whatever base the endpoint gives.
    static func bridgeURL(_ base: URL, _ path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: base.absoluteString + "/" + trimmed) else { return base }
        return url
    }

    // MARK: Plumbing

    private static func url(for profile: String, base: URL) throws -> URL {
        let name = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure.noProfile }
        // Component by component, so a profile with a space or a slash is percent-encoded rather
        // than reshaping the path.
        return base
            .appendingPathComponent("v1")
            .appendingPathComponent("bots")
            .appendingPathComponent(name)
            .appendingPathComponent("session")
    }

    private static func detail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["detail"] as? String
    }
}

// MARK: - What to do with the answer

/// What the bridge said about this bot's conversation.
public enum EndlessSessionPointerState: Equatable, Sendable {
    /// The bridge answered with an id. It is authoritative — the other device may be on it now.
    case value(SessionID)
    /// The bridge answered, and has no id for this bot yet.
    case absent
    /// The bridge could not be asked (offline, no route, unreadable answer). Not an error the user
    /// sees: the local cache answers instead and nothing is published, so a read we could not
    /// trust never overwrites the other device's pointer.
    case unavailable
}

/// The decision `AppModel.endlessSession(for:)` carries out.
public struct EndlessSessionPlan: Equatable, Sendable {

    public enum Step: Equatable, Sendable {
        /// Resume this stored id (never a runtime id — see the design note §5.6).
        case resume(SessionID)
        /// Mint a new conversation.
        case create
    }

    public enum Origin: Equatable, Sendable {
        /// The bridge's pointer.
        case host
        /// This device's `UserDefaults` cache.
        case local
        /// Neither: the conversation is about to be created.
        case none
    }

    public let step: Step
    public let origin: Origin
    /// Whether the resulting stored id must be written back to the bridge, so the other device
    /// adopts it on its next open.
    public let publish: Bool

    public init(step: Step, origin: Origin, publish: Bool) {
        self.step = step
        self.origin = origin
        self.publish = publish
    }

    public var resumedID: SessionID? {
        if case .resume(let id) = step { return id }
        return nil
    }
}

/// Which stored session to open, given the bridge's pointer and this device's cache.
///
/// The rules, in the order they matter:
///
/// 1. **Host wins.** A value the bridge holds is the shared answer; a stale local key is replaced.
/// 2. **Local is the fallback.** With no host value (or an unaskable host) the last id this device
///    used still opens — that is what keeps the app working offline and on an older bridge.
/// 3. **Publish what the host does not know.** After a create, and after a local id was adopted
///    because the bridge answered "nothing", the result is written back so the other device
///    converges. Nothing is published when the host supplied the id (it already knows) nor when
///    the read failed (that value may exist and must not be clobbered).
public enum EndlessSessionPolicy {

    /// A usable stored id, or `nil` for anything a resume could not be trusted with.
    ///
    /// The host's stored keys look like `20261106_165329_293f4b`; a trimmed, non-empty token of
    /// path-safe characters is the whole contract. Empty strings, whitespace, embedded newlines,
    /// path separators and absurdly long values are treated as "no pointer" rather than passed
    /// through to `session.resume` — a malformed answer must degrade to the local cache, never
    /// break the open.
    public static func storedID(_ raw: String?) -> SessionID? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...128).contains(trimmed.count) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        guard !trimmed.hasPrefix(".") else { return nil }
        return trimmed
    }

    public static func plan(host: EndlessSessionPointerState, local: String?) -> EndlessSessionPlan {
        let localID = storedID(local)

        switch host {
        case .value(let raw):
            guard let id = storedID(raw) else {
                // The bridge answered with something unusable; fall through to the same rules as
                // "no value", including publishing whatever we end up on so it is repaired.
                return planWithoutHost(localID)
            }
            return EndlessSessionPlan(step: .resume(id), origin: .host, publish: false)

        case .absent:
            return planWithoutHost(localID)

        case .unavailable:
            // Fail open: the local id still opens the conversation, but a read we could not
            // trust must not overwrite a pointer that may exist.
            if let localID {
                return EndlessSessionPlan(step: .resume(localID), origin: .local, publish: false)
            }
            return EndlessSessionPlan(step: .create, origin: .none, publish: true)
        }
    }

    private static func planWithoutHost(_ localID: SessionID?) -> EndlessSessionPlan {
        if let localID {
            return EndlessSessionPlan(step: .resume(localID), origin: .local, publish: true)
        }
        return EndlessSessionPlan(step: .create, origin: .none, publish: true)
    }
}

/// Characters allowed inside one URL path *component* supplied by the host.
///
/// `urlPathAllowed` deliberately keeps `/`, so a value meant to be a single segment can escape onto
/// another path. Subtracting the separator keeps it one segment; letters, digits, `-`, `_` and `.`
/// survive.
public enum URLPath {
    public static let componentAllowed: CharacterSet = CharacterSet.urlPathAllowed
        .subtracting(CharacterSet(charactersIn: "/"))
}
