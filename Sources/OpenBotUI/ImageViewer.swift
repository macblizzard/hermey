import Foundation
import ImageIO
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// An image, close to its own size, with the verbs a picture deserves.
///
/// A thumbnail in a transcript is a promise: "the picture is here". Clicking one and getting nothing —
/// which is what both apps did — makes the person go and find the file by hand, and a picture the
/// *host* produced had no surface at all. This is the one viewer both of those paths open, so an
/// attachment somebody sent and an artifact a bot generated are looked at the same way.
///
/// Zoom is a control as well as a gesture: +/−, `Fit`, and a pinch, so it works with a mouse, a
/// trackpad and a keyboard. Save writes the exact bytes that arrived and copy puts the picture on the
/// pasteboard — the bytes are never re-encoded, because a viewer that alters the file it shows is
/// worse than no viewer.
public struct ImageViewer: View {
    /// The encoded bytes, as they arrived.
    public let data: Data
    /// The file's name: the caption, and the name a save starts from.
    public let title: String
    /// Called by Close, Esc, or Done.
    public let onClose: () -> Void

    @State private var zoom: CGFloat = 1
    /// The zoom a pinch started from, so a gesture multiplies rather than jumps.
    @State private var pinchBase: CGFloat?
    @State private var didCopy = false
    @State private var failure: String?
    #if os(iOS)
    /// Where `Share` reads from: the bytes written once, on demand.
    @State private var sharedFile: URL?
    #endif

    public init(data: Data, title: String, onClose: @escaping () -> Void) {
        self.data = data
        self.title = title
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            picture
            Hairline()
            footer
        }
        .frame(minWidth: 320, minHeight: 260)
        .background(Tokens.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image viewer: \(title)")
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(TypeScale.font(TypeScale.md, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(Tokens.textSecondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close the image")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        guard let size = Self.pixelSize(of: data) else { return bytes }
        return "\(Int(size.width)) × \(Int(size.height)) · \(bytes)"
    }

    private var picture: some View {
        GeometryReader { geometry in
            ZStack {
                Tokens.frame
                if let image = Self.image(from: data) {
                    image
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(zoom, anchor: .center)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .gesture(pinch)
                } else {
                    // A file the decoder cannot read is still worth naming: a corrupt or exotic
                    // format should not look like a broken viewer.
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 22))
                        Text("This image cannot be previewed")
                            .font(TypeScale.font(TypeScale.label))
                    }
                    .foregroundStyle(Tokens.textMuted)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .accessibilityLabel("The image \(title)")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { zoom = max(1, zoom - 0.25) } label: {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(zoom <= 1 ? Tokens.textDim : Tokens.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(zoom <= 1)
            .help("Zoom out")
            .accessibilityLabel("Zoom out")

            Text("\(Int((zoom * 100).rounded())) %")
                .font(.system(size: TypeScale.label, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Tokens.textSecondary)
                .frame(width: 46)

            Button { zoom = min(4, zoom + 0.25) } label: {
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(zoom >= 4 ? Tokens.textDim : Tokens.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(zoom >= 4)
            .help("Zoom in")
            .accessibilityLabel("Zoom in")

            Button("Fit") { zoom = 1 }
                .buttonStyle(.plain)
                .foregroundStyle(zoom == 1 ? Tokens.textDim : Tokens.accentText)
                .disabled(zoom == 1)

            Spacer(minLength: 8)

            if let failure {
                Text(failure)
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.warning)
                    .lineLimit(1)
            } else if didCopy {
                Text("Copied")
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.success)
            }

            Button("Copy") { copy() }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.textSecondary)

            #if os(macOS)
            Button("Save…") { saveToDisk() }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.accentText)
            #else
            if let sharedFile {
                ShareLink(item: sharedFile) {
                    Text("Share")
                        .foregroundStyle(Tokens.accentText)
                }
                .buttonStyle(.plain)
            } else {
                Button("Share") { sharedFile = Self.writeTemporaryFile(data: data, name: title) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.accentText)
            }
            #endif

            OpenBotButton("Done", kind: .primary) { onClose() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Gestures

    private var pinch: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let base = pinchBase ?? zoom
                if pinchBase == nil { pinchBase = base }
                zoom = min(4, max(1, base * value))
            }
            .onEnded { _ in pinchBase = nil }
    }

    // MARK: Plumbing

    static func image(from data: Data) -> Image? {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #endif
    }

    /// The pixel dimensions, read from the header instead of decoding the whole file.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double
        else { return nil }
        return CGSize(width: width, height: height)
    }

    private func copy() {
        failure = nil
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        let board = NSPasteboard.PasteboardType.png
        pasteboard.clearContents()
        if pasteboard.setData(data, forType: board) {
            didCopy = true
        } else if let image = NSImage(data: data), pasteboard.writeObjects([image]) {
            didCopy = true
        } else {
            failure = "Copy failed"
        }
        #else
        if let image = UIImage(data: data) {
            UIPasteboard.general.image = image
            didCopy = true
        } else {
            failure = "Copy failed"
        }
        #endif
    }

    #if os(macOS)
    private func saveToDisk() {
        failure = nil
        let panel = NSSavePanel()
        panel.nameFieldStringValue = title.isEmpty ? "image.png" : title
        panel.canCreateDirectories = true
        let bytes = data
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try bytes.write(to: url, options: .atomic)
                didCopy = false
            } catch {
                failure = error.localizedDescription
            }
        }
    }
    #else
    /// The bytes, once, in a temp file the share sheet can carry.
    static func writeTemporaryFile(data: Data, name: String) -> URL? {
        let safe = name.isEmpty ? "image.png" : name
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
    #endif
}
