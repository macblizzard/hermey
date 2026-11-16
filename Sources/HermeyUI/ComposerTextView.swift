import Foundation

// The payload type is platform-neutral: the phone builds the same attachments from its own
// pickers, and `Composer` declares the closure that takes them on both platforms.
/// One thing a paste or a drop wants to attach.
public struct ComposerAttachment: Equatable {
    public let name: String
    public let data: Data
    public let isImage: Bool

    public init(name: String, data: Data, isImage: Bool) {
        self.name = name
        self.data = data
        self.isImage = isImage
    }
}

#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Mac composer's editor: a real `NSTextView`.
///
/// `TextField(axis: .vertical)` could grow with its text, but it could not break a line **where
/// the caret is**: it exposes no selection, and once a key handler has seen ⌘-less Return, returning
/// `.ignored` does not hand the key back — so the break had to be appended to the binding, which
/// always landed at the end of the draft.
///
/// A text view inserts at the caret, which is the entire requirement. Return is intercepted here
/// (it sends); Shift+Return and ⌥⇧⏎ are left to AppKit, which inserts the break at the selection the
/// way every other field on the platform does.
/// The editor, with the two ways a picture gets into a Mac message: ⌘V and a drop.
///
/// `NSTextView` would otherwise swallow both. `importsGraphics` is off (the draft is plain text),
/// so a pasted screenshot was dropped on the floor, and a dropped file became its path typed into
/// the message. An attachment is not a character: both routes are handed to the composer, which
/// puts them where the paperclip puts them.
final class ComposerEditorView: NSTextView {
    var onAttachItems: (([ComposerAttachment]) -> Void)?

    /// The prompt, drawn by the text system rather than by a SwiftUI `Text` on top of it.
    ///
    /// The two disagreed: a `Text` positions a string by its own ascent, while the caret is a line
    /// fragment's full height, so the caret sat a few points above the placeholder's cap. Drawn
    /// here, the prompt and the caret come from the same font and the same origin, and a typed
    /// character lands exactly where the prompt was.
    var placeholderText: String = "" {
        didSet { if placeholderText != oldValue { needsDisplay = true } }
    }
    var placeholderColor: NSColor = .tertiaryLabelColor {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderText.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: placeholderColor,
        ]
        (placeholderText as NSString).draw(at: textContainerOrigin, withAttributes: attributes)
    }

    /// The prompt has to appear and disappear with the first character — `NSTextView` does not
    /// redraw for an empty string otherwise.
    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func paste(_ sender: Any?) {
        if attach(from: .general) { return }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.attachments(from: sender.draggingPasteboard) == nil
            ? super.draggingEntered(sender)
            : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.attachments(from: sender.draggingPasteboard) == nil
            ? super.draggingUpdated(sender)
            : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if attach(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    @discardableResult
    private func attach(from pasteboard: NSPasteboard) -> Bool {
        guard onAttachItems != nil, let items = Self.attachments(from: pasteboard) else { return false }
        onAttachItems?(items)
        return true
    }

    /// The attachments a pasteboard carries, or `nil` when it is ordinary text.
    ///
    /// Files win over text on purpose: a Finder copy carries the file's path as a string as well,
    /// and attaching the file is what was meant. Plain text wins over image data, so copying a
    /// link out of a page pastes the link rather than a picture of it.
    static func attachments(from pasteboard: NSPasteboard) -> [ComposerAttachment]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let files = urls.filter { !$0.hasDirectoryPath }.compactMap { url -> ComposerAttachment? in
                guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
                let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                    ?? UTType(filenameExtension: url.pathExtension)
                return ComposerAttachment(name: url.lastPathComponent, data: data,
                                          isImage: type?.conforms(to: .image) ?? false)
            }
            if !files.isEmpty { return files }
        }

        if pasteboard.string(forType: .string) != nil, pasteboard.data(forType: .tiff) == nil {
            return nil
        }

        guard let png = imageData(from: pasteboard) else { return nil }
        return [ComposerAttachment(name: "Pasted image.png", data: png, isImage: true)]
    }

    /// PNG bytes for whatever picture the pasteboard holds, converting a TIFF (what most apps put
    /// on the pasteboard) when there is no PNG to take.
    private static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var fontSize: CGFloat
    /// The one-line floor and the ceiling where the field starts scrolling inside itself.
    var minHeight: CGFloat
    var maxHeight: CGFloat
    /// False while the composer has nothing to send into (no bot, no session): the field must not
    /// take keystrokes it would then throw away.
    var isEditable: Bool
    var onSend: () -> Void
    var onHeightChange: (CGFloat) -> Void
    /// Files and pictures pasted or dropped into the field, in the order they arrived.
    var onAttachItems: (([ComposerAttachment]) -> Void)?
    /// The prompt, for an empty field. Drawn by the text view itself (see `ComposerEditorView`).
    var placeholder: String
    var placeholderColor: NSColor

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// The inset that puts the first line in the middle of a row of controls.
    ///
    /// The paperclip, the microphone and the send arrow are squares on the row's centre line; the
    /// text has no such box, so its line is centred by hand. Without this the glyphs sat a few
    /// points off each other — the "alignment is not quite right" the composer was reported for.
    static func firstLineInset(fontSize: CGFloat, rowHeight: CGFloat) -> CGFloat {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: nsFont(size: fontSize))
        return max(0, (rowHeight - lineHeight) / 2)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        let textView = ComposerEditorView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = isEditable
        if let editor = textView as? ComposerEditorView {
            editor.placeholderText = placeholder
            editor.placeholderColor = placeholderColor
            editor.onAttachItems = { items in context.coordinator.parent.onAttachItems?(items) }
        }
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        // Smart quotes and dashes rewrite the user's ports, flags and paths.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = Self.nsFont(size: fontSize)
        textView.textColor = NSColor(Tokens.textPrimary)
        textView.insertionPointColor = NSColor(Tokens.accent)
        textView.textContainerInset = NSSize(width: 0,
                                             height: Self.firstLineInset(fontSize: fontSize,
                                                                         rowHeight: minHeight))
        textView.placeholderText = placeholder
        textView.placeholderColor = placeholderColor
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.onAttachItems = { items in context.coordinator.parent.onAttachItems?(items) }
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: maxHeight)
        // No line-fragment padding: the prompt is drawn at `textContainerOrigin`, and the caret
        // is the insertion point of the first fragment. With the default 5 pt of padding the
        // prompt started left of the caret, which put the caret inside the first letter.
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView

        DispatchQueue.main.async { context.coordinator.resize(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // The parent carries the newest closures and sizes; the coordinator only lives as long as
        // the view does.
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }

        if textView.string != text {
            // A dictation transcript, a cleared draft after a send, a restored per-bot draft.
            let caret = textView.selectedRange().location
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(caret, length), length: 0))
            context.coordinator.resize(textView)
        }

        textView.isEditable = isEditable
        if let editor = textView as? ComposerEditorView {
            editor.placeholderText = placeholder
            editor.placeholderColor = placeholderColor
            editor.onAttachItems = { items in context.coordinator.parent.onAttachItems?(items) }
        }

        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    /// The composer draws in the same face the rest of the app does: Inter when it is actually
    /// available, the system font otherwise, at a hinted size. `NSFont(name:)` wants a PostScript
    /// name, not a family, so it always answered nil for Inter and silently drew the system font at
    /// an unrounded size.
    static func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let points = TypeScale.pointSize(size)
        if NSFontManager.shared.availableFontFamilies.contains("Inter"),
           let inter = NSFont(name: "Inter", size: points) {
            return inter
        }
        return NSFont.systemFont(ofSize: points, weight: weight)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        private var lastReportedHeight: CGFloat = 0

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if parent.text != view.string { parent.text = view.string }
            resize(view)
            // Past the eight-line cap the field scrolls inside itself, and AppKit does not move the
            // clip view for us when the *frame* is fixed from the outside: the caret slid below the
            // visible range and the user was typing blind.
            view.scrollRangeToVisible(view.selectedRange())
        }

        func textViewDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ notification: Notification) {
            if parent.isFocused { parent.isFocused = false }
        }

        /// Return sends; Shift+Return falls through to AppKit, which inserts the break at the caret.
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) { return false }
            parent.onSend()
            return true
        }

        /// Arrow keys, clicks, selection drags: wherever the caret ends up, keep it on screen.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            view.scrollRangeToVisible(view.selectedRange())
        }

        /// Report the height the text needs, clamped, so the card grows by a line at a time instead
        /// of jumping to a fixed size.
        func resize(_ view: NSTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + view.textContainerInset.height * 2
            // The document view is as tall as the text, always: the clip view is what is clamped to
            // `maxHeight`, and a document that stops growing is a document that cannot scroll to the
            // caret. This — not the missing `scrollRangeToVisible` — is why typing past the cap ran
            // below the visible box.
            let contentHeight = max(used, parent.minHeight)
            if let clip = view.enclosingScrollView?.contentView,
               abs(view.frame.height - contentHeight) > 0.5 {
                view.setFrameSize(NSSize(width: clip.bounds.width, height: contentHeight))
            }
            let height = min(contentHeight, parent.maxHeight)
            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            let report = parent.onHeightChange
            DispatchQueue.main.async { report(height) }
        }
    }
}
#endif
