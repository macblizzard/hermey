import Foundation

/// The schema this build writes, and the only one it reads.
///
/// A share payload is a file on disk that outlives both processes that touch it: the extension is
/// dismissed seconds after writing it, and the app may not run again until the phone is unlocked.
/// A reader that guessed at a shape it did not write would deliver the wrong text to the wrong
/// bot, so the version is checked before a single field is read and an unknown one is refused
/// rather than decoded into a half-empty payload.
public enum SharePayloadSchema {
    public static let version = 1
    /// The payload lands as `<uuid>.json`; the extension is the only writer.
    public static let payloadFileExtension = "json"
    /// A payload older than this is treated as undeliverable rather than surprising.
    public static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
}

/// Why a payload could not be read. Not user-facing: the app logs nothing the user typed and the
/// extension has already closed by the time a reader sees this.
public enum SharePayloadError: Error, Equatable {
    case unsupportedVersion(found: Int)
}

/// One byte blob carried beside the payload.
///
/// `fileName` is relative to the payload's asset directory inside the App Group container — it is
/// never an absolute path and never a URL inside the extension's temporary directory, because that
/// directory is deleted the moment the share sheet closes.
public struct ShareAttachment: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case image
        case file
    }

    public var id: UUID
    public var kind: Kind
    public var fileName: String
    /// The UTI the provider advertised, kept so the app can name the file it hands the host.
    public var typeIdentifier: String?
    /// What the share sheet called it ("IMG_0042.HEIC"), for the app's own attachment name.
    public var originalName: String?
    public var byteCount: Int

    public init(id: UUID = UUID(),
                kind: Kind,
                fileName: String,
                typeIdentifier: String? = nil,
                originalName: String? = nil,
                byteCount: Int = 0) {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.typeIdentifier = typeIdentifier
        self.originalName = originalName
        self.byteCount = byteCount
    }
}

/// Everything one share-sheet pass produced, addressed to one bot.
public struct SharePayload: Codable, Hashable, Sendable, Identifiable {
    public var version: Int
    public var id: UUID
    public var createdAt: Date
    /// The profile name the host's `POST /v1/bots/{profile}/message` takes. Chosen in the sheet.
    public var botID: String
    /// What the picker showed for that bot, so a conversation can name it before it loads.
    public var botName: String
    public var text: String?
    public var urlString: String?
    public var attachments: [ShareAttachment]

    public init(id: UUID = UUID(),
                createdAt: Date = Date(),
                botID: String,
                botName: String = "",
                text: String? = nil,
                urlString: String? = nil,
                attachments: [ShareAttachment] = []) {
        // Every payload this build writes carries the version it was written with; `version` is
        // not a caller argument for the same reason a length prefix is not: it can only be wrong.
        self.version = SharePayloadSchema.version
        self.id = id
        self.createdAt = createdAt
        self.botID = botID
        let trimmedName = botName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.botName = trimmedName.isEmpty ? botID : trimmedName
        self.text = text
        self.urlString = urlString
        self.attachments = attachments
    }

    public var images: [ShareAttachment] { attachments.filter { $0.kind == .image } }
    public var files: [ShareAttachment] { attachments.filter { $0.kind == .file } }

    /// Nothing to deliver: an empty text body, no link, no bytes. A payload like this is never
    /// written — the sheet disables Send instead.
    public var isEmpty: Bool {
        let body = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let link = urlString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return body.isEmpty && link.isEmpty && attachments.isEmpty
    }

    /// The message the app should send, with the link appended when the share carried both.
    /// The URL is a field of its own on disk so a future client can render a link card; joining
    /// them here keeps one definition of "what the bot sees".
    public var messageText: String {
        let body = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let link = urlString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (body.isEmpty, link.isEmpty) {
        case (false, false):
            return body.contains(link) ? body : "\(body)\n\(link)"
        case (false, true):
            return body
        case (true, false):
            return link
        case (true, true):
            return ""
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, createdAt, botID, botName, text, urlString, attachments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let found = try container.decode(Int.self, forKey: .version)
        guard found == SharePayloadSchema.version else {
            throw SharePayloadError.unsupportedVersion(found: found)
        }
        self.version = found
        self.id = try container.decode(UUID.self, forKey: .id)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.botID = try container.decode(String.self, forKey: .botID)
        let name = try container.decodeIfPresent(String.self, forKey: .botName)
        self.botName = name ?? self.botID
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.urlString = try container.decodeIfPresent(String.self, forKey: .urlString)
        self.attachments = try container.decodeIfPresent([ShareAttachment].self, forKey: .attachments) ?? []
    }
}
