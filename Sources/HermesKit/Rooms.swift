import Foundation

// MARK: - Models

/// One bot in a group chat's roster.
public struct RoomMemberSummary: Identifiable, Hashable, Sendable {
    public let profile: String
    public let handle: String
    public let displayName: String

    public init(profile: String, handle: String, displayName: String) {
        self.profile = profile
        self.handle = handle
        self.displayName = displayName
    }

    public var id: String { profile }
    /// What the transcript shows beside a reply, and what a mention types.
    public var mention: String { handle.isEmpty ? profile : handle }
}

/// A group chat: a hosted Hermes room with a frozen roster.
public struct RoomSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let members: [RoomMemberSummary]
    public let updatedAt: Date?
    public let latestSeq: Int?
    /// Who spoke last: `you`, or the bot's profile name. Nil before anyone has said anything.
    public let lastSpeaker: String?
    public let lastFromOwner: Bool
    public let lastText: String?
    public let lastAt: Date?

    public init(id: String, name: String, members: [RoomMemberSummary],
                updatedAt: Date? = nil, latestSeq: Int? = nil,
                lastSpeaker: String? = nil, lastFromOwner: Bool = false,
                lastText: String? = nil, lastAt: Date? = nil) {
        self.id = id
        self.name = name
        self.members = members
        self.updatedAt = updatedAt
        self.latestSeq = latestSeq
        self.lastSpeaker = lastSpeaker
        self.lastFromOwner = lastFromOwner
        self.lastText = lastText
        self.lastAt = lastAt
    }

    public func member(for profile: String) -> RoomMemberSummary? {
        members.first { $0.profile == profile }
    }
}

/// One spoken line in a room. Turn markers are filtered out on the host side, so everything the app
/// receives is either the owner or a bot.
public struct RoomMessage: Identifiable, Hashable, Sendable {
    public let seq: Int
    public let eventID: String
    /// `you`, or the bot's profile name.
    public let speaker: String
    public let isOwner: Bool
    public let text: String
    public let at: Date?
    public let inReplyTo: String?

    public init(seq: Int, eventID: String, speaker: String, isOwner: Bool,
                text: String, at: Date? = nil, inReplyTo: String? = nil) {
        self.seq = seq
        self.eventID = eventID
        self.speaker = speaker
        self.isOwner = isOwner
        self.text = text
        self.at = at
        self.inReplyTo = inReplyTo
    }

    public var id: String { eventID.isEmpty ? "seq-\(seq)" : eventID }
}

/// One file travelling with a room message.
///
/// A room's messages are text on the host, so a file cannot travel as a file: the bridge writes it
/// beside its own database and the message carries the absolute path, which is what the member
/// bots open. This type is the wire shape of that bargain.
public struct RoomAttachment: Hashable, Sendable {
    public let name: String
    public let data: Data
    public let isImage: Bool

    public init(name: String, data: Data, isImage: Bool) {
        self.name = name
        self.data = data
        self.isImage = isImage
    }
}

/// A page of a room's log, plus the high-water mark to ask from next time.
public struct RoomPage: Sendable {
    public let messages: [RoomMessage]
    public let latestSeq: Int

    public init(messages: [RoomMessage], latestSeq: Int) {
        self.messages = messages
        self.latestSeq = latestSeq
    }
}

// MARK: - Bridge surface

/// The bridge's room routes (`/v1/rooms…`), defaulted onto the session-pointer store because it is
/// the one object that already knows the bridge endpoint and mints the single-use ticket each HTTP
/// request needs.
public extension BotSessionPointerStore {
    func rooms() async throws -> [RoomSummary] { [] }
    func createRoom(name: String, members: [String]) async throws -> RoomSummary {
        throw BotAdminUnavailable()
    }
    func roomPage(_ roomID: String, since seq: Int?) async throws -> RoomPage {
        throw BotAdminUnavailable()
    }
    func sendRoomMessage(_ roomID: String, text: String, attachments: [RoomAttachment]) async throws {
        try await sendRoomMessage(roomID, text: text)
    }
    func disbandRoom(_ roomID: String) async throws {}
    func renameRoom(_ roomID: String, name: String) async throws {}
}

extension BridgeBotSessionPointer {
    /// `GET /v1/rooms`.
    public func rooms() async throws -> [RoomSummary] {
        let data = try await bridgeGET("v1/rooms")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["rooms"] as? [[String: Any]] else { return [] }
        return rows.compactMap(Self.room(from:))
    }

    /// `POST /v1/rooms` — a name plus the bot profiles that join it.
    public func createRoom(name: String, members: [String]) async throws -> RoomSummary {
        let data = try await bridgePOST("v1/rooms",
                                        body: ["name": name, "members": members.map { ["profile": $0] }])
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let room = object["room"] as? [String: Any],
              let summary = Self.room(from: room) else {
            throw RoomFailure.unreadable
        }
        return summary
    }

    /// `GET /v1/rooms/{id}/log?since_seq=` — the delta after `seq`, or the whole thread.
    public func roomPage(_ roomID: String, since seq: Int?) async throws -> RoomPage {
        var path = "v1/rooms/\(roomID)/log"
        if let seq, seq > 0 { path += "?since_seq=\(seq)" }
        let data = try await bridgeGET(path)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RoomFailure.unreadable
        }
        let rows = object["events"] as? [[String: Any]] ?? []
        return RoomPage(messages: rows.compactMap(Self.message(from:)),
                        latestSeq: object["latest_seq"] as? Int ?? 0)
    }

    /// `POST /v1/rooms/{id}/send` — one message; the bots it names are the ones that answer.
    public func sendRoomMessage(_ roomID: String, text: String) async throws {
        try await sendRoomMessage(roomID, text: text, attachments: [])
    }

    public func sendRoomMessage(_ roomID: String, text: String,
                                attachments: [RoomAttachment]) async throws {
        var body: [String: Any] = ["text": text]
        if !attachments.isEmpty {
            body["attachments"] = attachments.map {
                ["name": $0.name,
                 "data_base64": $0.data.base64EncodedString(),
                 "is_image": $0.isImage]
            }
        }
        _ = try await bridgePOST("v1/rooms/\(roomID)/send", body: body)
    }

    /// `POST /v1/rooms/{id}/rename` — the host's own verb (`groups.rename`), so the name lives
    /// where the room lives: every device and every member's view agree, and the rename event is
    /// part of the room's log.
    ///
    /// This has to be declared on the *concrete* store. The protocol's default is a no-op
    /// (`func renameRoom(…) async throws {}` in `public extension BotSessionPointerStore`), so a
    /// store that merely forgets this one inherits "succeed and do nothing": the app renames
    /// locally, re-reads the list from the host, and shows the old name with no error anywhere.
    public func renameRoom(_ roomID: String, name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try await bridgePOST("v1/rooms/\(roomID)/rename", body: ["name": trimmed])
    }

    /// `POST /v1/rooms/{id}/disband` — remove the room for good. Same trap as the rename: the
    /// protocol default returns without a request, so deleting a group chat would look like it
    /// worked until the next list reload brought it back.
    public func disbandRoom(_ roomID: String) async throws {
        _ = try await bridgePOST("v1/rooms/\(roomID)/disband", body: [:])
    }

    // MARK: Decoding

    private static func room(from row: [String: Any]) -> RoomSummary? {
        guard let id = row["room_id"] as? String, !id.isEmpty else { return nil }
        let members = (row["members"] as? [[String: Any]] ?? []).compactMap { member -> RoomMemberSummary? in
            guard let profile = member["profile"] as? String else { return nil }
            return RoomMemberSummary(profile: profile,
                                     handle: member["handle"] as? String ?? profile,
                                     displayName: member["display_name"] as? String ?? profile)
        }
        let updated = (row["updated_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let lastAt = (row["last_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return RoomSummary(id: id,
                           name: row["name"] as? String ?? id,
                           members: members,
                           updatedAt: updated,
                           latestSeq: row["latest_seq"] as? Int,
                           lastSpeaker: row["last_speaker"] as? String,
                           lastFromOwner: row["last_from_owner"] as? Bool ?? false,
                           lastText: row["last_text"] as? String,
                           lastAt: lastAt)
    }

    private static func message(from row: [String: Any]) -> RoomMessage? {
        guard let seq = row["seq"] as? Int, let text = row["text"] as? String else { return nil }
        let actor = row["actor"] as? [String: Any] ?? [:]
        let kind = actor["kind"] as? String ?? ""
        let label = actor["label"] as? String ?? actor["profile"] as? String ?? "bot"
        let at = (row["at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return RoomMessage(seq: seq,
                           eventID: row["event_id"] as? String ?? "",
                           speaker: label,
                           isOwner: kind == "user",
                           text: text,
                           at: at,
                           inReplyTo: row["in_reply_to"] as? String)
    }
}

public enum RoomFailure: LocalizedError {
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "The host answered with something this app could not read."
        }
    }
}
