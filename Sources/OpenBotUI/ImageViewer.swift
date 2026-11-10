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
/// which is what both apps did — makes the person go and find the file by hand. This is the one viewer
/// those thumbnails open.
///
/// The verbs are the picture's, not the app's. A picture *you* sent is already yours: it has no Save,
/// because saving it back to the disk it came from is busywork. A picture the host produced, or one
/// that arrived from somewhere else, does get Save — that is the point of being able to look at it.
///
/// Zoom is a control as well as a gesture: +/−, `Fit`, and a pinch. The bytes drawn are the bytes that
/// arrived, never a re-encoding.
public struct ImageViewer: View {
    /// The encoded bytes, as they arrived.
    public let data: Data
    /// The file's name: the caption, and the name a save starts from.
    public let title: String
    /// Whether the picture can leave the viewer (Save on the Mac, Share on the phone). Off for a
    /// picture the person already owns.
    public let canExport: Bool
    /// Called by Close, Esc, or Done.
    public let onClose: () -> Void

    @State private var zoom: CGFloat = 1
    /// The zoom a pinch started from, so a gesture multiplies rather than jumps.
    @State private var pinchBase: CGFloat?
    /// A brief word about the last action — over the picture, not in the footer, where it would push
    /// the buttons out of the way on a phone.
    @State private var notice: String?
    #if os(iOS)
    /// Where `Share` reads from: the bytes written once, on demand.
    @State private var sharedFile: URL?
    #endif

    public init(data: Data, title: String, canExport: Bool = true, onClose: @escaping () -> Void) {
        self.data = data
        self.title = title
        self.canExport = canExport
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
        .frame(minWidth: 320, minHeight: 240)
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Tokens.textSecondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            #if os(macOS)
            .help("Close")
            #endif
            .accessibilityLabel("Close the image")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
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
                if let notice {
                    Text(notice)
                        .font(TypeScale.font(TypeScale.label, weight: .medium))
                        .foregroundStyle(Tokens.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Tokens.control, in: Capsule())
                        .padding(.bottom, 14)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .accessibilityLabel("The image \(title)")
        }
    }

    private var footer: some View {
        HStack(spacing: Self.footerGap) {
            zoomControls
            Spacer(minLength: 4)
            exportControls
            OpenBotButton("Done", kind: .primary, size: .small) { onClose() }
                .fixedSize()
                .layoutPriority(2)
        }
        .padding(.horizontal, Self.footerPadding)
        .padding(.vertical, 9)
    }

    private var zoomControls: some View {
        HStack(spacing: Self.footerGap) {
            iconButton("minus.magnifyingglass", enabled: zoom > 1, label: "Zoom out") {
                zoom = max(1, zoom - 0.25)
            }
            Text("\(Int((zoom * 100).rounded())) %")
                .font(.system(size: TypeScale.label, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Tokens.textSecondary)
                .frame(width: 42)
                .fixedSize()
            iconButton("plus.magnifyingglass", enabled: zoom < 4, label: "Zoom in") {
                zoom = min(4, zoom + 0.25)
            }
            Button("Fit") { zoom = 1 }
                .font(TypeScale.font(TypeScale.label))
                .buttonStyle(.plain)
                .foregroundStyle(zoom == 1 ? Tokens.textDim : Tokens.accentText)
                .disabled(zoom == 1)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var exportControls: some View {
        iconButton("doc.on.doc", enabled: true, label: "Copy") { copy() }
        if canExport {
            #if os(macOS)
            Button("Save…") { saveToDisk() }
                .font(TypeScale.font(TypeScale.label))
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.accentText)
                .fixedSize()
            #else
            if let sharedFile {
                ShareLink(item: sharedFile) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14))
                        .foregroundStyle(Tokens.accentText)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share")
            } else {
                iconButton("square.and.arrow.up", enabled: true, label: "Share", tint: Tokens.accentText) {
                    sharedFile = Self.writeTemporaryFile(data: data, name: title)
                    say("Ready to share")
                }
            }
            #endif
        }
    }

    private func iconButton(_ systemName: String,
                            enabled: Bool,
                            label: String,
                            tint: Color = Tokens.textSecondary,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .foregroundStyle(enabled ? tint : Tokens.textDim)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        #if os(macOS)
        .help(label)
        #endif
        .accessibilityLabel(label)
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

    #if os(iOS)
    private static let footerGap: CGFloat = 6
    private static let footerPadding: CGFloat = 10
    #else
    private static let footerGap: CGFloat = 10
    private static let footerPadding: CGFloat = 14
    #endif

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

    /// A word over the picture for a moment, then gone.
    private func say(_ word: String) {
        withAnimation(.easeOut(duration: 0.15)) { notice = word }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeOut(duration: 0.25)) { notice = nil }
        }
    }

    private func copy() {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setData(data, forType: .png) {
            say("Copied")
        } else if let image = NSImage(data: data), pasteboard.writeObjects([image]) {
            say("Copied")
        } else {
            say("Copy failed")
        }
        #else
        if let image = UIImage(data: data) {
            UIPasteboard.general.image = image
            say("Copied")
        } else {
            say("Copy failed")
        }
        #endif
    }

    #if os(macOS)
    private func saveToDisk() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = title.isEmpty ? "image.png" : title
        panel.canCreateDirectories = true
        let bytes = data
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try bytes.write(to: url, options: .atomic)
                say("Saved")
            } catch {
                say("Save failed")
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
