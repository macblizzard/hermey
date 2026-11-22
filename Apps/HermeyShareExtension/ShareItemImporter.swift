#if os(iOS)
import Foundation
import UniformTypeIdentifiers

/// What the sheet is about to send, before it is fixed to a bot.
struct ShareDraft: Equatable {
    var text: String?
    var urlString: String?
    var attachments: [ShareAttachment] = []
    /// Items the sheet offered that were too large or unreadable. Said out loud in the summary
    /// line, because a silently dropped photo looks like a successful share.
    var skipped: Int = 0

    var images: [ShareAttachment] { attachments.filter { $0.kind == .image } }
    var files: [ShareAttachment] { attachments.filter { $0.kind == .file } }

    var isEmpty: Bool {
        let body = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let link = urlString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return body.isEmpty && link.isEmpty && attachments.isEmpty
    }
}

/// Turns `NSExtensionItem`s into a draft, copying every byte into the App Group as it goes.
///
/// The rule this type exists to enforce: nothing here hands the app a URL. A share sheet's
/// attachments are borrowed — `loadFileRepresentation` writes into a directory that is deleted when
/// the extension is torn down, and the extension is torn down the instant Send is tapped. So every
/// item is read to `Data` and written into `Share/Inbox/Assets/` while this process is still alive.
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
                switch kind(of: provider) {
                case .image(let type):
                    if let data = try? await loadData(provider, typeIdentifier: type.identifier),
                       let attachment = try? storage.importAttachment(
                        data,
                        kind: .image,
                        typeIdentifier: type.identifier,
                        originalName: provider.suggestedName,
                        fileExtension: type.preferredFilenameExtension,
                        for: payloadID) {
                        draft.attachments.append(attachment)
                    } else {
                        draft.skipped += 1
                    }
                case .url(let type):
                    if let value = try? await loadURLString(provider, typeIdentifier: type.identifier) {
                        // A link shared with a caption sends both; a bare link is the text.
                        if draft.urlString == nil { draft.urlString = value }
                        else if draft.text == nil { draft.text = value }
                    } else {
                        draft.skipped += 1
                    }
                case .fileURL(let type):
                    // A PDF shared from Files is a file URL, not a link to a web page. Read it here,
                    // while the URL is still valid, and copy the bytes into the group container.
                    if let file = try? await loadFileURL(provider, typeIdentifier: type.identifier),
                       let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                       size <= maximumAttachmentBytes,
                       let data = try? Data(contentsOf: file, options: .mappedIfSafe) {
                        let looksLikeImage = UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) ?? false
                        if let attachment = try? storage.importAttachment(
                            data,
                            kind: looksLikeImage ? .image : .file,
                            typeIdentifier: UTType(filenameExtension: file.pathExtension)?.identifier,
                            originalName: provider.suggestedName ?? file.lastPathComponent,
                            fileExtension: file.pathExtension,
                            for: payloadID) {
                            draft.attachments.append(attachment)
                        } else {
                            draft.skipped += 1
                        }
                    } else {
                        draft.skipped += 1
                    }
                case .text(let type):
                    if let value = try? await loadText(provider, typeIdentifier: type.identifier) {
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            if draft.text == nil { draft.text = trimmed }
                            else { draft.text = (draft.text ?? "") + "\n" + trimmed }
                        }
                    }
                case .file(let type):
                    if let data = try? await loadData(provider, typeIdentifier: type.identifier),
                       let attachment = try? storage.importAttachment(
                        data,
                        kind: .file,
                        typeIdentifier: type.identifier,
                        originalName: provider.suggestedName,
                        fileExtension: type.preferredFilenameExtension,
                        for: payloadID) {
                        draft.attachments.append(attachment)
                    } else {
                        draft.skipped += 1
                    }
                case .none:
                    draft.skipped += 1
                }
            }
        }
        return draft
    }

    // MARK: - What a provider is

    private enum ProviderKind {
        case image(UTType)
        case url(UTType)
        case text(UTType)
        case file(UTType)
        case fileURL(UTType)
    }

    /// Images win over files, and a file URL wins over a web URL: a PDF shared from Files conforms
    /// to `public.url` too, and treating it as a link would send a `file://` path to the bot.
    private static func kind(of provider: NSItemProvider) -> ProviderKind? {
        if let type = conformingType(of: provider, to: .image) { return .image(type) }
        if let type = conformingType(of: provider, to: .fileURL) { return .fileURL(type) }
        if let type = conformingType(of: provider, to: .url) { return .url(type) }
        if let type = conformingType(of: provider, to: .text) { return .text(type) }
        if let type = conformingType(of: provider, to: .data) { return .file(type) }
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

    // MARK: - Reading

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
                    continuation.resume(throwing: error ?? ShareImportError.unreadable)
                }
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider, typeIdentifier: String) async throws -> String {
        guard let item = try await loadItem(provider, typeIdentifier: typeIdentifier) else {
            throw ShareImportError.unreadable
        }
        switch item {
        case let string as String:
            return string
        case let attributed as NSAttributedString:
            return attributed.string
        case let data as Data:
            guard let string = String(data: data, encoding: .utf8) else { throw ShareImportError.unreadable }
            return string
        case let url as NSURL:
            return (url as URL).absoluteString
        default:
            throw ShareImportError.unreadable
        }
    }

    private static func loadURLString(_ provider: NSItemProvider, typeIdentifier: String) async throws -> String {
        guard let item = try await loadItem(provider, typeIdentifier: typeIdentifier) else {
            throw ShareImportError.unreadable
        }
        switch item {
        case let url as NSURL:
            return (url as URL).absoluteString
        case let string as String:
            guard let url = URL(string: string), url.scheme != nil else { throw ShareImportError.unreadable }
            return url.absoluteString
        case let data as Data:
            guard let string = String(data: data, encoding: .utf8),
                  let url = URL(string: string), url.scheme != nil else { throw ShareImportError.unreadable }
            return url.absoluteString
        default:
            throw ShareImportError.unreadable
        }
    }

    private static func loadFileURL(_ provider: NSItemProvider, typeIdentifier: String) async throws -> URL {
        guard let item = try await loadItem(provider, typeIdentifier: typeIdentifier) else {
            throw ShareImportError.unreadable
        }
        switch item {
        case let url as NSURL:
            return url as URL
        case let data as Data:
            // Some hosts hand the path as bytes rather than an NSURL.
            guard let path = String(data: data, encoding: .utf8) else { throw ShareImportError.unreadable }
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ShareImportError.unreadable }
            return URL(fileURLWithPath: trimmed)
        default:
            throw ShareImportError.unreadable
        }
    }

    private enum ShareImportError: Error {
        case unreadable
    }
}
#endif
