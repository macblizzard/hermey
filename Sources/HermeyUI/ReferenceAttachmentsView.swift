import Foundation
import HermesKit
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The attachments a stored message names, drawn — on either device.
///
/// A message carries *references*, not bytes: `@image:/…/upload_ab12.jpg` for a photo,
/// `@file:…/attachments/MICs.xlsx` for a workbook. The device that attached it has the bytes; the
/// other one has this string, and until now drew it as a path inside the prose (which is what "I
/// don't see that image on my Mac" was). This view is the other half of the host's
/// `GET /v1/attachments?profile=&path=` route: one renderer, used by both shells, because the
/// reference is identical whichever device wrote it.
///
/// What it draws:
///
///   * a picture as a rounded inline thumbnail, capped in height, with a corner glyph that says it
///     opens — a press hands the bytes to the shell's viewer;
///   * anything else as a chip: the type's symbol, the file's own name, its size, a press that
///     fetches it and hands the shell a URL to open;
///   * while the bytes are on their way, the same chip in its loading state, *named* — never a
///     blank space;
///   * and when the host cannot answer (unreachable, a refused path, a 404, too large) an
///     "Unavailable" chip that still names the file and says why. An error that looks like an error
///     is the point: a path shown as prose looks like content, and that is the bug this replaces.
///
/// The bytes themselves are cached by `AttachmentReferenceReader` — the in-memory LRU keyed by the
/// reference, then the on-disk cache keyed by the host's file name — so a re-render and a second row
/// naming the same file cost nothing.
public struct ReferenceAttachmentsView: View {

    public let attachments: [MessageAttachment]
    /// The profile the references belong to: the host resolves a path inside *this* profile, so a
    /// device paired to `cody` cannot be pointed at `jason`'s uploads.
    public let profile: String
    /// Bytes this device already holds — a memory or disk cache read, so it is synchronous.
    public let cachedBytes: (MessageAttachment) -> Data?
    /// Fetch from the host, through whatever route the app already uses to open a file.
    public let load: (MessageAttachment) async throws -> Data
    /// Show a picture the row holds. The shell chooses the viewer.
    public let onOpenImage: (MessageAttachment, Data) -> Void
    /// Show a file, from a local URL a viewer can open.
    public let onOpenFile: (MessageAttachment, URL) -> Void
    /// The widest a picture may be drawn. Height is capped at `thumbnailHeight`; a portrait photo
    /// stays a thumbnail rather than running the whole bubble off the screen.
    public let thumbnailWidth: CGFloat
    public let thumbnailHeight: CGFloat

    @State private var pictures: [String: Data] = [:]
    @State private var failures: [String: String] = [:]

    public init(attachments: [MessageAttachment],
                profile: String,
                cachedBytes: @escaping (MessageAttachment) -> Data?,
                load: @escaping (MessageAttachment) async throws -> Data,
                onOpenImage: @escaping (MessageAttachment, Data) -> Void,
                onOpenFile: @escaping (MessageAttachment, URL) -> Void,
                thumbnailWidth: CGFloat = 240,
                thumbnailHeight: CGFloat = 180) {
        self.attachments = attachments
        self.profile = profile
        self.cachedBytes = cachedBytes
        self.load = load
        self.onOpenImage = onOpenImage
        self.onOpenFile = onOpenFile
        self.thumbnailWidth = thumbnailWidth
        self.thumbnailHeight = thumbnailHeight
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                row(for: attachment)
            }
        }
    }

    @ViewBuilder
    private func row(for attachment: MessageAttachment) -> some View {
        if let reason = failures[attachment.id] {
            ReferenceUnavailableChip(name: attachment.name, reason: reason) {
                retry(attachment)
            }
        } else if attachment.isImage, let data = bytes(for: attachment), let picture = Image(imageBytes: data) {
            Button { onOpenImage(attachment, data) } label: {
                thumbnail(picture)
            }
            .buttonStyle(.plain)
            .help("Open \(attachment.name)")
            .accessibilityLabel("Attached image \(attachment.name)")
            .accessibilityHint("Opens the image")
            .hermeyFocusQuiet()
        } else if attachment.isImage, bytes(for: attachment) != nil {
            // The bytes are here but this platform cannot decode them (a HEIC on an old macOS, say).
            // Named, with the reason, rather than a spinner that would never finish.
            AttachmentFileRow(name: attachment.name,
                              kind: .image,
                              size: attachment.size,
                              status: .failed("not a picture this device can draw"),
                              onOpen: { openFile(attachment) },
                              onRetry: { openFile(attachment) })
                .frame(maxWidth: 320)
        } else {
            // No bytes yet: a picture is on its way, and a document is waiting to be pressed. Either
            // way the file is named while nothing can be drawn for it.
            AttachmentFileRow(name: attachment.name,
                              kind: attachment.kindOfFile,
                              size: attachment.size,
                              status: attachment.isImage ? .loading : .ready,
                              onOpen: { openFile(attachment) },
                              onRetry: { retry(attachment) })
                .frame(maxWidth: 320)
                .task(id: attachment.id) {
                    // A picture is fetched on sight — a thumbnail that only appears after a press is
                    // not a thumbnail. A document is fetched when it is pressed, so a chat with a
                    // dozen files asks the host for none of them.
                    if attachment.isImage { await fetch(attachment) }
                }
        }
    }

    // MARK: Drawing

    /// A rounded thumbnail with the corner glyph that promises it opens.
    ///
    /// A fixed box, not the picture's own aspect: forty photos of forty shapes in one column would
    /// otherwise be forty heights, and the transcript is a list. `scaledToFill` keeps the picture's
    /// proportions inside it.
    private func thumbnail(_ picture: Image) -> some View {
        picture
            .resizable()
            .scaledToFill()
            .frame(width: thumbnailWidth, height: thumbnailHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Tokens.borderStrong, lineWidth: 1)
            )
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Tokens.textSecondary)
                    .padding(4)
                    .background(Tokens.canvas.opacity(0.75), in: Circle())
                    .padding(5)
            }
            .accessibilityElement(children: .ignore)
    }

    // MARK: Resolution

    private func bytes(for attachment: MessageAttachment) -> Data? {
        if let fetched = pictures[attachment.id] { return fetched }
        return cachedBytes(attachment)
    }

    /// Fetch one attachment and remember the bytes for this row.
    private func fetch(_ attachment: MessageAttachment) async {
        if bytes(for: attachment) != nil { return }
        do {
            let data = try await load(attachment)
            pictures[attachment.id] = data
            failures[attachment.id] = nil
        } catch {
            // The reason is the row's second line, so it is the error's own words — a 404 for a file
            // the host no longer has reads "That file is not on the host yet." and an unreachable
            // host says so.
            failures[attachment.id] = Self.reason(for: error)
        }
    }

    /// A press on a document: fetch, then hand the shell a URL a viewer can open.
    ///
    /// `@MainActor` because the thing at the end of it is: a viewer and a share sheet both belong to
    /// the main thread, and the two `@State` writes above are read by the next body pass.
    private func openFile(_ attachment: MessageAttachment) {
        Task { @MainActor in
            do {
                let data: Data
                if let held = bytes(for: attachment) {
                    data = held
                } else {
                    data = try await load(attachment)
                    pictures[attachment.id] = data
                    failures[attachment.id] = nil
                }
                guard let url = AttachmentFileCache.store(
                    data, for: .reference(profile: profile, path: attachment.path)
                ) else {
                    failures[attachment.id] = AttachmentFetchError.cacheUnavailable.localizedDescription
                    return
                }
                if attachment.isImage {
                    onOpenImage(attachment, data)
                } else {
                    onOpenFile(attachment, url)
                }
            } catch {
                failures[attachment.id] = Self.reason(for: error)
            }
        }
    }

    private func retry(_ attachment: MessageAttachment) {
        failures[attachment.id] = nil
        pictures[attachment.id] = nil
        Task { @MainActor in await fetch(attachment) }
    }

    /// What the chip says under the file's name. A 404 keeps its quiet register ("not on the host");
    /// everything else is the fetch error's own sentence, which already names the status.
    static func reason(for error: Error) -> String {
        if let fetch = error as? AttachmentFetchError {
            if fetch.isNotReady { return "not on the host" }
            if let words = fetch.errorDescription { return words }
        }
        if let words = (error as? LocalizedError)?.errorDescription, !words.isEmpty {
            return words
        }
        return "could not be loaded"
    }
}

/// The chip a reference wears when its bytes cannot be had.
///
/// It names the file, says why, and retries on a press — three things a blank space does none of.
/// Deliberately *not* a file row: a row without bytes is a file that is not here, not a file that
/// failed, and the difference matters when the host is simply asleep.
public struct ReferenceUnavailableChip: View {
    public let name: String
    public let reason: String
    public let onRetry: () -> Void

    @State private var isHovered = false

    public init(name: String, reason: String, onRetry: @escaping () -> Void) {
        self.name = name
        self.reason = reason
        self.onRetry = onRetry
    }

    public var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Tokens.danger)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(TypeScale.font(TypeScale.caption, weight: .medium))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Unavailable — \(reason)")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if isHovered {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Tokens.accentText)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .fill(Tokens.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .strokeBorder(Tokens.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        )
        .contentShape(RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous))
        .onTapGesture(perform: onRetry)
        .onHover { isHovered = $0 }
        .help("Try \(name) again")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Attached file \(name), unavailable")
        .accessibilityValue(Text(reason))
        .accessibilityHint("Tries to load it again")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Bytes to an image, on either platform

extension Image {
    /// `Data` as SwiftUI's image, without the app branching on the platform at every call site. The
    /// bytes are what arrived; nothing is re-encoded.
    ///
    /// Failable rather than a placeholder: a grey photo glyph standing in for a picture that did
    /// arrive, but that this platform cannot decode, is a lie about what is here. The row says so
    /// instead.
    init?(imageBytes data: Data) {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        self.init(uiImage: image)
        #elseif os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        self.init(nsImage: image)
        #else
        return nil
        #endif
    }
}
