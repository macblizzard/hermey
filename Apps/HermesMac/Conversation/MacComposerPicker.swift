import AppKit
import Foundation
import HermesAppKit
import HermesKit
import HermeyUI
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The composer's one door to attachments: a single panel for any file on disk, with the Photos
/// library one visible button inside the panel's own chrome.
///
/// The library was never a folder the Finder can show. `NSOpenPanel` browses paths and a picture
/// in Photos has none, so no file browser — the old menu's "Photos…" entry, which opened the same
/// panel filtered to images, or the single `.item` panel that replaced it — could ever reach the
/// library. The way in therefore rides in the panel's `accessoryView`: one click still opens
/// exactly one panel, the accessory says "Photos…" from the moment the panel is up, and pressing
/// it ends that panel into the system photo picker instead of opening anything on top of it.
///
/// Both routes then stage bytes through `MacAttachmentFile` and `stage(_:in:failure:)`, so the
/// empty/over-budget check, the HEIC transcode inside `AppModel.addPendingAttachment` and the
/// failure alert are one implementation with two callers — never a second code path for bytes.
@MainActor
enum MacComposerPicker {
    /// What the click produced.
    ///
    /// `.photos` is the accessory button only: the panel has already closed, and presenting the
    /// photo picker is the caller's job — it needs the window the composer lives in, which this
    /// static entry point does not own.
    enum Outcome: Equatable {
        case cancelled
        case filesStaged
        case photos
    }

    /// One click, one panel, any file.
    static func chooseAttachments(for model: AppModel) -> Outcome {
        let panel = NSOpenPanel()
        // `.item` is the whole tree on purpose: a `.zip`, a `.wav`, a `.tsv` is a file the host
        // can stage, and the host refuses what it cannot read with a reason. Narrowing this list
        // again is what made an unrelated file unpickable.
        panel.allowedContentTypes = [.item]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        panel.message = "Choose photos or files to attach"
        // No `directoryURL`: the panel's own memory of the last folder is the feature, and setting
        // one would overwrite it on every open.

        let target = PhotosButtonTarget()
        var wantsPhotos = false
        panel.accessoryView = photosAccessoryView(target)
        target.onPress = { [weak panel] in
            wantsPhotos = true
            // End this modal session rather than stacking a sheet on it: the button's whole
            // promise is that the click that opened the panel is the click that reaches Photos.
            panel?.orderOut(nil)
            NSApp.stopModal(withCode: .cancel)
        }

        let response = panel.runModal()

        // The response is `.cancel` either way, so the flag — not the code — says which door the
        // user took.
        guard !wantsPhotos else { return .photos }
        guard response == .OK else { return .cancelled }

        var files: [MacAttachmentFile] = []
        var firstFailure: Error?
        for url in panel.urls {
            do {
                files.append(try MacAttachmentFile.read(url))
            } catch {
                // One unreadable file does not sink the batch: the rest still attach, and the
                // failure is reported once at the end.
                if firstFailure == nil { firstFailure = error }
            }
        }
        stage(files, in: model, failure: firstFailure)
        return .filesStaged
    }

    /// The one place picked bytes reach the composer.
    ///
    /// Both callers land here — the panel with what it read off disk, the photo picker with what
    /// it decoded — so the alert, the staging order and the model's own size/HEIC handling cannot
    /// drift apart.
    static func stage(_ files: [MacAttachmentFile], in model: AppModel, failure: Error? = nil) {
        var notice = failure
        for file in files {
            let before = model.lastSendError
            model.addPendingAttachment(name: file.name, data: file.data, isImage: file.isImage)
            // `addPendingAttachment` refuses by *setting* the error — an over-budget JPEG after
            // the transcode, a ninth attachment — rather than throwing, so a fresh one is worth
            // showing and a stale one from an earlier send is not.
            if notice == nil, let after = model.lastSendError, after != before {
                notice = NSError(domain: "attach", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: after])
            }
        }
        guard let notice else { return }
        // A typed notice, like the phone's alert: picking nothing and picking something
        // unreadable must not look the same.
        let alert = NSAlert()
        alert.messageText = "Could not attach that file"
        alert.informativeText = notice.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Accessory

    /// The panel's own chrome, laid out like a macOS accessory bar: a separator, a normal rounded
    /// button, and a line of words that says why the button exists.
    private static func photosAccessoryView(_ target: PhotosButtonTarget) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 48))
        // The panel sizes the accessory to its width; the height is ours.
        container.autoresizingMask = [.width]

        let button = NSButton(title: "Photos…", target: target,
                              action: #selector(PhotosButtonTarget.press(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.toolTip = "Pictures in Photos are not folders on disk — this opens your library."
        button.setAccessibilityLabel("Choose photos from your Photos library")

        let note = NSTextField(labelWithString: "Your Photos library, not a folder")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [button, note])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(rule)
        container.addSubview(row)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: container.topAnchor),
            rule.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 2),
        ])
        return container
    }
}

/// The accessory button's target. AppKit needs a selector, so the closure lives one object away.
@MainActor
private final class PhotosButtonTarget: NSObject {
    var onPress: (() -> Void)?

    @objc func press(_ sender: Any?) { onPress?() }
}

/// One file read off disk — or one picture decoded from the library — bounded by the host's own
/// limit.
struct MacAttachmentFile {
    let name: String
    let data: Data
    let isImage: Bool

    enum Failure: LocalizedError {
        case empty
        case tooLarge
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "The selected file is empty."
            case .tooLarge:
                return "The attachment exceeds the 8 MB upload limit."
            case .unreadable(let why):
                return why
            }
        }
    }

    /// Validated construction, for bytes that never came off a path.
    ///
    /// The photo picker hands over a blob with no file to stat, and it has to clear the same two
    /// bars the disk read enforces — non-empty, inside the 8 MB the transcode and the frame budget
    /// assume — or the two routes would disagree about what is attachable.
    init(name: String, data: Data, isImage: Bool) throws {
        guard !data.isEmpty else { throw Failure.empty }
        guard data.count <= AppModel.maxAttachmentBytes else { throw Failure.tooLarge }
        self.name = name
        self.data = data
        self.isImage = isImage
    }

    static func read(_ url: URL) throws -> MacAttachmentFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let isImage = isImageFile(url)

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        defer { try? handle.close() }

        let bytes = (try? handle.read(upToCount: AppModel.maxAttachmentBytes + 1)) ?? Data()
        return try MacAttachmentFile(name: url.lastPathComponent, data: bytes, isImage: isImage)
    }

    private static func isImageFile(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .image) {
            return true
        }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// A library picture arrives with no filename, and the extension is not decoration: it is what
    /// `ImageTranscoding` reads to decide whether to re-encode a HEIC. So it comes from the bytes
    /// rather than from the picker's advertised types, whose first image type can be
    /// `public.jpeg` even when the representation is HEIC.
    static func photoName(_ data: Data, index: Int) -> String {
        var ext = ImageTranscoding.jpegExtension
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let raw = CGImageSourceGetType(source),
           let preferred = UTType(raw as String)?.preferredFilenameExtension {
            ext = preferred
        }
        return "Photo \(index + 1).\(ext)"
    }
}
