import AppKit
import Foundation
import Quartz

/// Quick Look for a file the conversation names.
///
/// A document the person attached, or the bot wrote a moment ago, is shown the way the Finder shows
/// one: a real Quick Look preview, not a text dump in a sheet. `QLPreviewView` is used inside a
/// small reusable window rather than the shared `QLPreviewPanel`: the panel needs a data source
/// object with delegate conformances that outlive every row that might have asked for it, while a
/// window this class owns is one object, on the main actor, with the file it is showing.
///
/// Nothing is written outside the attachment cache — the URL handed in is already a cached file, so
/// closing the window leaves nothing behind in the repository or the user's Documents.
@MainActor
final class MacAttachmentQuickLook {
    static let shared = MacAttachmentQuickLook()

    private var window: NSWindow?
    private var preview: QLPreviewView?

    private init() {}

    /// Show one file. The window is reused, so opening three files in a row does not leave three
    /// windows behind; the title is the file's own name.
    func show(_ url: URL, title: String? = nil) {
        let name = title ?? url.lastPathComponent
        if let window, let preview {
            preview.previewItem = url as NSURL
            preview.refreshPreviewItem()
            window.title = name
            window.makeKeyAndOrderFront(nil)
            return
        }

        // A local name: the stored `preview` is optional, so assigning its member here would not
        // compile — and the stored one is only set once the window exists.
        let view = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 820, height: 600),
                                 style: .normal)
        view.previewItem = url as NSURL

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = name
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
        self.preview = view
    }
}
