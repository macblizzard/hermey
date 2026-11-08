import AppKit
import Foundation
import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI
import UniformTypeIdentifiers

/// The paperclip's compact menu: Photos and Files, nothing else.
///
/// The phone opens an action sheet and then a system picker; on the Mac the picker *is* the panel,
/// so the menu is two items in a popover — no page, no sheet, and no upload on pick. The bytes are
/// handed to `AppModel.addPendingAttachment`, which is where the size limit and the empty-file
/// check live, so both platforms validate the same way.
struct MacAttachmentMenu: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            item("Photos…", symbol: "photo") { chooseImages() }
            item("Files…", symbol: "folder") { chooseFiles() }
        }
        .padding(6)
        .frame(width: 180)
        .background(Tokens.sheet)
    }

    private func item(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            isPresented = false
            action()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textSecondary)
                    .frame(width: 14)
                Text(title)
                    .font(TypeScale.font(Tokens.textSM))
                    .foregroundStyle(Tokens.textPrimary)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // No focus ring: a popover of two items is not a keyboard-navigated list, and macOS drew
        // a blue ring inside the menu the moment it opened.
        .focusable(false)
        .hoverFill()
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous))
    }

    // MARK: Picking

    private func chooseImages() {
        pick(contentTypes: [.image], prompt: "Choose a photo to attach")
    }

    private func chooseFiles() {
        pick(contentTypes: [.item], prompt: "Choose a file to attach")
    }

    private func pick(contentTypes: [UTType], prompt: String) {
        let panel = NSOpenPanel()
        // The panel took one file per trip; a batch of screenshots meant reopening it each time.
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = contentTypes
        panel.prompt = "Attach"
        panel.message = prompt

        guard panel.runModal() == .OK else { return }

        // One unreadable file does not sink the batch: the rest still attach, and the failure is
        // reported once at the end.
        var firstFailure: Error?
        for url in panel.urls {
            do {
                let file = try MacAttachmentFile.read(url)
                model.addPendingAttachment(name: file.name, data: file.data, isImage: file.isImage)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        // A typed notice, like the phone's alert: picking nothing and picking something
        // unreadable must not look the same.
        if let failure = firstFailure ?? model.lastSendError.map({ NSError(domain: "attach", code: 1,
                                                                          userInfo: [NSLocalizedDescriptionKey: $0]) }) {
            let alert = NSAlert()
            alert.messageText = "Could not attach that file"
            alert.informativeText = failure.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

/// One file read off disk, bounded by the host's own limit.
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
        guard !bytes.isEmpty else { throw Failure.empty }
        guard bytes.count <= AppModel.maxAttachmentBytes else { throw Failure.tooLarge }

        return MacAttachmentFile(name: url.lastPathComponent, data: bytes, isImage: isImage)
    }

    private static func isImageFile(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .image) {
            return true
        }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}

// MARK: - Previews

private struct MacAttachmentMenuPreview: View {
    @StateObject private var store = PreviewWorkspace.store()
    @State private var presented = true

    var body: some View {
        MacAttachmentMenu(model: store.model, isPresented: $presented)
            .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Attachment menu") {
    MacAttachmentMenuPreview()
}
#endif
