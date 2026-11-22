#if os(iOS)
import Foundation
import UniformTypeIdentifiers

/// One thing the sheet could not carry, named, with the reason it could not.
///
/// The reason is an enum rather than a pre-baked sentence so the sentence can only say what
/// actually happened: "too large" exists only when a real byte ceiling was hit, and it carries that
/// ceiling with it. A file refused because its URL could not be opened — the common case for a share
/// from Files — says it could not be read, and says what the system said.
struct ShareImportIssue: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// A real limit was hit, with the numbers that prove it.
        case tooLarge(byteCount: Int, maximumBytes: Int)
        /// The bytes could not be read. `detail` is the system's own words, or ours when it gave none.
        case unreadable(detail: String)
        /// Nothing about the item is a shape this sheet can send.
        case unsupported
    }

    var name: String
    var reason: Reason

    /// The line the sheet shows. One cause per sentence.
    var message: String {
        switch reason {
        case .tooLarge(let byteCount, let maximumBytes):
            return "\(name) is \(Self.size(byteCount)) — over the \(Self.size(maximumBytes)) limit for one share."
        case .unreadable(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Could not read \(name)." : "Could not read \(name): \(trimmed)"
        case .unsupported:
            return "\(name) is not a kind of item Hermey can send."
        }
    }

    /// "12 MB", not "12582912 bytes": a limit is only useful if it can be read.
    static func size(_ bytes: Int) -> String {
        let megabytes = Double(bytes) / (1024 * 1024)
        if megabytes >= 10 { return "\(Int(megabytes.rounded())) MB" }
        if megabytes >= 1 { return String(format: "%.1f MB", megabytes) }
        let kilobytes = Double(bytes) / 1024
        return kilobytes >= 1 ? "\(Int(kilobytes.rounded())) KB" : "\(bytes) bytes"
    }
}

/// What the sheet is about to send, before it is fixed to a bot.
struct ShareDraft: Equatable, Sendable {
    var text: String?
    var urlString: String?
    var attachments: [ShareAttachment] = []
    /// Items that were genuinely refused. Kept per item, not as a count: a silently dropped file
    /// looks like a successful share, and "1 item was too large" is a claim that may be false.
    var issues: [ShareImportIssue] = []

    var images: [ShareAttachment] { attachments.filter { $0.kind == .image } }
    var files: [ShareAttachment] { attachments.filter { $0.kind == .file } }

    var isEmpty: Bool {
        let body = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let link = urlString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return body.isEmpty && link.isEmpty && attachments.isEmpty
    }

    /// The refused items as one paragraph, or `nil` when everything offered was carried.
    var issueSummary: String? {
        guard !issues.isEmpty else { return nil }
        return issues.map(\.message).joined(separator: "\n")
    }
}

/// Turns `NSExtensionItem`s into a draft, copying every byte into the App Group as it goes.
///
/// The rule this type exists to enforce: nothing here hands the app a URL. A share sheet's
/// attachments are borrowed — `loadFileRepresentation` writes into a directory that is deleted when
/// the extension is torn down, and the extension is torn down the instant Send is tapped. So every
/// item is read to `Data` and written into `Share/Inbox/Assets/` while this process is still alive.
///
/// The second rule, learned from the first real share: **a file the person picked is a file, not a
/// picture and not a link.** Files.app hands over a security-scoped file URL with no image type on
/// it, and every read of that URL — bytes and metadata alike — fails unless the scope is open. An
/// importer that asks for the size before opening the scope gets `nil`, calls the item skipped, and
/// the sheet tells the owner a 12 KB text file "was too large". So the scope is opened first here,
/// and a size is only ever measured from bytes that were actually read.
enum ShareItemImporter {
    /// The same ceiling `ShareInboxStorage` enforces; checked before loading so a 4K video is not
    /// pulled into memory just to be refused.
    static let maximumAttachmentBytes = ShareInboxStorage.maximumAttachmentBytes

    static func draft(from items: [NSExtensionItem],
                      payloadID: UUID,
                      storage: ShareInboxStorage) async -> ShareDraft {
        var draft = ShareDraft()
        for item in items {
            for provider in item.attachments ?? [] {
                guard let providerKind = kind(of: provider) else {
                    // No type identifier at all: nothing to read, and the sentence says so.
                    draft.issues.append(ShareImportIssue(name: displayName(for: provider, file: nil),
                                                         reason: .unsupported))
                    continue
                }
                // Read first, fold in after: the draft is only touched between awaits.
                let outcome: ImportOutcome
                switch providerKind {
                case .fileURL(let type):
                    // A PDF or a text file shared from Files is a file URL, not a link to a web
                    // page. Read it here, while the URL is still valid, and copy the bytes in.
                    outcome = await fileURLOutcome(provider,
                                                   registeredType: type,
                                                   payloadID: payloadID,
                                                   storage: storage)
                case .image(let type):
                    outcome = await dataOutcome(provider,
                                                typeIdentifier: type.identifier,
                                                kind: .image,
                                                storedTypeIdentifier: type.identifier,
                                                fileExtension: type.preferredFilenameExtension,
                                                payloadID: payloadID,
                                                storage: storage)
                case .url(let type):
                    outcome = await urlOutcome(provider, typeIdentifier: type.identifier)
                case .text(let type):
                    outcome = await textOutcome(provider, typeIdentifier: type.identifier)
                case .file(let type):
                    outcome = await dataOutcome(provider,
                                                typeIdentifier: type.identifier,
                                                kind: .file,
                                                storedTypeIdentifier: type.identifier,
                                                fileExtension: type.preferredFilenameExtension,
                                                payloadID: payloadID,
                                                storage: storage)
                case .rawFile(let identifier):
                    // A provider whose only registered type is one nothing above recognises — a
                    // document exported by an app with its own UTI, say. It is still the item the
                    // person chose, so it is tried as bytes rather than refused on principle.
                    outcome = await dataOutcome(provider,
                                                typeIdentifier: identifier,
                                                kind: .file,
                                                storedTypeIdentifier: identifier,
                                                fileExtension: UTType(identifier)?.preferredFilenameExtension,
                                                payloadID: payloadID,
                                                storage: storage)
                }
                absorb(outcome, into: &draft)
            }
        }
        return draft
    }

    // MARK: - What a provider is

    private enum ProviderKind {
        case fileURL(UTType)
        case image(UTType)
        case url(UTType)
        case text(UTType)
        case file(UTType)
        /// Nothing recognised: the provider's own first type identifier, tried as bytes.
        case rawFile(String)
    }

    /// A file URL wins over everything.
    ///
    /// `public.file-url` conforms to `public.url`, and an image picked in Files conforms to
    /// `public.image` too — but both arrive as a file the person chose, and only the file URL says
    /// where its bytes are. Classifying either as a link would send a `file://` path to the bot, and
    /// classifying a PDF as an image would leave the sheet with no preview and no attachment.
    private static func kind(of provider: NSItemProvider) -> ProviderKind? {
        if let type = conformingType(of: provider, to: .fileURL) { return .fileURL(type) }
        if let type = conformingType(of: provider, to: .image) { return .image(type) }
        if let type = conformingType(of: provider, to: .url) { return .url(type) }
        if let type = conformingType(of: provider, to: .text) { return .text(type) }
        if let type = conformingType(of: provider, to: .data) { return .file(type) }
        // Last resort. `public.item` does not conform to `public.data`, so a provider that names
        // only that would otherwise be refused although it can still hand over bytes.
        if let identifier = provider.registeredTypeIdentifiers.first { return .rawFile(identifier) }
        return nil
    }

    /// The registered type itself, not the umbrella: `public.jpeg`, not `public.image`.
    private static func conformingType(of provider: NSItemProvider, to wanted: UTType) -> UTType? {
        for identifier in provider.registeredTypeIdentifiers {
            guard let candidate = UTType(identifier), candidate.conforms(to: wanted) else { continue }
            // `public.data` is every provider's parent; it is only a useful answer for files.
            if wanted == .data && candidate == .data { continue }
            return candidate
        }
        return provider.hasItemConformingToTypeIdentifier(wanted.identifier) ? wanted : nil
    }

    /// What to call the item in a sentence about it. The person's own file name wherever there is one.
    private static func displayName(for provider: NSItemProvider, file: URL?) -> String {
        let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !suggested.isEmpty { return suggested }
        if let file, !file.lastPathComponent.isEmpty { return file.lastPathComponent }
        return "This item"
    }

    // MARK: - Outcomes

    /// What one provider produced: bytes, text, a link, or a reason it produced none.
    private struct ImportOutcome {
        var attachment: ShareAttachment?
        var text: String?
        var urlString: String?
        var issue: ShareImportIssue?

        static func refused(_ issue: ShareImportIssue) -> ImportOutcome {
            ImportOutcome(issue: issue)
        }
    }

    /// Folds one provider's result into the draft. Link and text precedence lives here so every
    /// branch of the switch above agrees about which of a caption and its link becomes the message.
    private static func absorb(_ outcome: ImportOutcome, into draft: inout ShareDraft) {
        if let attachment = outcome.attachment { draft.attachments.append(attachment) }
        if let link = outcome.urlString {
            // A link shared with a caption sends both; a bare link is the text.
            if draft.urlString == nil { draft.urlString = link }
            else if draft.text == nil { draft.text = link }
        }
        if let text = outcome.text {
            if draft.text == nil { draft.text = text }
            else { draft.text = (draft.text ?? "") + "\n" + text }
        }
        if let issue = outcome.issue { draft.issues.append(issue) }
    }

    // MARK: - Provider branches

    /// A file the person picked. Security scope opened first, size measured from the bytes read.
    private static func fileURLOutcome(_ provider: NSItemProvider,
                                       registeredType: UTType,
                                       payloadID: UUID,
                                       storage: ShareInboxStorage) async -> ImportOutcome {
        var file: URL?
        do {
            let located = try await loadFileURL(provider, typeIdentifier: registeredType.identifier)
            file = located
            let data = try readFile(located)
            // What the file *is*: from its extension first, the provider's own type second. A
            // `.jpeg` shared from Files is a picture and belongs in the thumbnail strip; a `.pdf`
            // is a file and must survive as one.
            let resolved = resolvedType(of: located, provider: provider)
            let isImage = resolved?.conforms(to: .image) ?? false
            let attachment = try storage.importAttachment(data,
                                                          kind: isImage ? .image : .file,
                                                          typeIdentifier: resolved?.identifier,
                                                          originalName: provider.suggestedName ?? located.lastPathComponent,
                                                          fileExtension: located.pathExtension,
                                                          for: payloadID)
            return ImportOutcome(attachment: attachment)
        } catch {
            return .refused(issue(name: displayName(for: provider, file: file), error: error))
        }
    }

    private static func dataOutcome(_ provider: NSItemProvider,
                                    typeIdentifier: String,
                                    kind: ShareAttachment.Kind,
                                    storedTypeIdentifier: String?,
                                    fileExtension: String?,
                                    payloadID: UUID,
                                    storage: ShareInboxStorage) async -> ImportOutcome {
        let name = displayName(for: provider, file: nil)
        do {
            let data = try await loadData(provider, typeIdentifier: typeIdentifier)
            let attachment = try storage.importAttachment(data,
                                                          kind: kind,
                                                          typeIdentifier: storedTypeIdentifier,
                                                          originalName: provider.suggestedName,
                                                          fileExtension: fileExtension,
                                                          for: payloadID)
            return ImportOutcome(attachment: attachment)
        } catch {
            return .refused(issue(name: name, error: error))
        }
    }

    private static func urlOutcome(_ provider: NSItemProvider,
                                   typeIdentifier: String) async -> ImportOutcome {
        do {
            let value = try await loadURLString(provider, typeIdentifier: typeIdentifier)
            return ImportOutcome(urlString: value)
        } catch {
            return .refused(issue(name: displayName(for: provider, file: nil), error: error))
        }
    }

    private static func textOutcome(_ provider: NSItemProvider,
                                    typeIdentifier: String) async -> ImportOutcome {
        guard let value = try? await loadText(provider, typeIdentifier: typeIdentifier) else {
            return .refused(ShareImportIssue(name: displayName(for: provider, file: nil),
                                             reason: .unreadable(detail: "the text could not be decoded.")))
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty text is not a failure: a share can carry a caption-less image, and an empty string
        // in the draft would make `isEmpty` false for nothing.
        return ImportOutcome(text: trimmed.isEmpty ? nil : trimmed)
    }

    // MARK: - Errors out loud

    /// Turns whatever went wrong into a reason the sheet can state without inventing anything.
    private static func issue(name: String, error: Error) -> ShareImportIssue {
        switch error {
        case let importError as ShareImportError:
            switch importError {
            case .tooLarge(let byteCount, let maximumBytes):
                return ShareImportIssue(name: name,
                                        reason: .tooLarge(byteCount: byteCount, maximumBytes: maximumBytes))
            case .unreadable(let detail):
                return ShareImportIssue(name: name, reason: .unreadable(detail: detail))
            }
        case let inboxError as ShareInboxError:
            switch inboxError {
            case .tooLarge(let byteCount, let maximumBytes):
                return ShareImportIssue(name: name,
                                        reason: .tooLarge(byteCount: byteCount, maximumBytes: maximumBytes))
            case .noContainer:
                return ShareImportIssue(name: name,
                                        reason: .unreadable(detail: "Hermey has no shared storage yet."))
            }
        default:
            let detail = (error as NSError).localizedDescription
            return ShareImportIssue(name: name, reason: .unreadable(detail: detail))
        }
    }

    // MARK: - Reading

    /// Reads a file the person chose, with its security scope open, and refuses it only for a
    /// reason it can state.
    ///
    /// `startAccessingSecurityScopedResource` returns `false` for a URL that needs no scope (a path
    /// inside the extension's own container), so the return value gates the *stop*, never the read.
    /// The size is checked twice — the cheap metadata answer first, the real byte count second —
    /// because a host can report no size at all, and because a real ceiling is the only thing that
    /// entitles the sheet to say "too large".
    private static func readFile(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true {
            throw ShareImportError.unreadable("that is a folder, not a file.")
        }
        if let size = values?.fileSize, size > maximumAttachmentBytes {
            throw ShareImportError.tooLarge(byteCount: size, maximumBytes: maximumAttachmentBytes)
        }
        // Not mapped: a mapping outlives the security scope, and these bytes are copied into the
        // container after the scope closes.
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ShareImportError.unreadable((error as NSError).localizedDescription)
        }
        guard !data.isEmpty else {
            throw ShareImportError.unreadable("the file is empty.")
        }
        guard data.count <= maximumAttachmentBytes else {
            throw ShareImportError.tooLarge(byteCount: data.count, maximumBytes: maximumAttachmentBytes)
        }
        return data
    }

    private static func resolvedType(of file: URL, provider: NSItemProvider) -> UTType? {
        if let byExtension = UTType(filenameExtension: file.pathExtension) { return byExtension }
        // No extension: the provider may still know (an exporter that names `public.jpeg`).
        return conformingType(of: provider, to: .image) ?? conformingType(of: provider, to: .data)
    }

    private static func loadItem(_ provider: NSItemProvider, typeIdentifier: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: item)
                }
            }
        }
    }

    private static func loadData(_ provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? ShareImportError.unreadable("the item was empty."))
                }
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider, typeIdentifier: String) async throws -> String {
        guard let item = try await loadItem(provider, typeIdentifier: typeIdentifier) else {
            throw ShareImportError.unreadable("the item was empty.")
        }
        switch item {
        case let string as String:
            return string
        case let attributed as NSAttributedString:
            return attributed.string
        case let data as Data:
            guard let string = String(data: data, encoding: .utf8) else {
                throw ShareImportError.unreadable("the text was not UTF-8.")
            }
            return string
        case let url as NSURL:
            return (url as URL).absoluteString
        default:
            throw ShareImportError.unreadable("the item was not text.")
        }
    }

    private static func loadURLString(_ provider: NSItemProvider, typeIdentifier: String) async throws -> String {
        guard let item = try await loadItem(provider, typeIdentifier: typeIdentifier) else {
            throw ShareImportError.unreadable("the link was empty.")
        }
        switch item {
        case let url as NSURL:
            return (url as URL).absoluteString
        case let string as String:
            guard let url = URL(string: string), url.scheme != nil else {
                throw ShareImportError.unreadable("the link was not a URL.")
            }
            return url.absoluteString
        case let data as Data:
            guard let string = String(data: data, encoding: .utf8),
                  let url = URL(string: string), url.scheme != nil else {
                throw ShareImportError.unreadable("the link was not a URL.")
            }
            return url.absoluteString
        default:
            throw ShareImportError.unreadable("the item was not a link.")
        }
    }

    private static func loadFileURL(_ provider: NSItemProvider, typeIdentifier: String) async throws -> URL {
        guard let item = try await loadItem(provider, typeIdentifier: typeIdentifier) else {
            throw ShareImportError.unreadable("the file location was empty.")
        }
        switch item {
        case let url as NSURL:
            return url as URL
        case let data as Data:
            // Some hosts hand the path as bytes rather than an NSURL.
            guard let path = String(data: data, encoding: .utf8) else {
                throw ShareImportError.unreadable("the file location could not be decoded.")
            }
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ShareImportError.unreadable("the file location was empty.")
            }
            return URL(fileURLWithPath: trimmed)
        default:
            throw ShareImportError.unreadable("the item was not a file location.")
        }
    }

    enum ShareImportError: Error, Equatable {
        case tooLarge(byteCount: Int, maximumBytes: Int)
        case unreadable(String)
    }
}
#endif
