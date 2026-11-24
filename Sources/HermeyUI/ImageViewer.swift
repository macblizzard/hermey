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
///
/// A message can carry several pictures. The viewer is then a small gallery: it opens on the one that
/// was tapped and pages through the rest — a horizontal swipe and a counter on the phone, the arrow
/// keys and chevrons on the Mac — so looking at the second picture no longer means closing the first.
///
/// On the phone a downward swipe puts the gallery away as well, the way every photo viewer there
/// does: the picture follows the finger, and letting go either closes it or springs it back.
public struct ImageViewer: View {
    /// One picture of the message: the bytes, and the name they were saved under.
    public struct Item: Identifiable {
        public let id = UUID()
        /// The encoded bytes, as they arrived.
        public let data: Data
        /// The file's name: the caption, and the name a save starts from.
        public let name: String

        public init(data: Data, name: String) {
            self.data = data
            self.name = name
        }
    }

    /// Every picture on offer, in the order the message carries them.
    public let items: [Item]
    /// Whether the picture can leave the viewer (Save on the Mac, Share on the phone). Off for a
    /// picture the person already owns.
    public let canExport: Bool
    /// Called by Close, Esc, or Done.
    public let onClose: () -> Void

    /// The picture on screen. The chrome — name, size, Copy, Save, Share — reads the current one.
    @State private var index: Int
    @State private var zoom: CGFloat = 1
    /// The zoom a pinch started from, so a gesture multiplies rather than jumps.
    @State private var pinchBase: CGFloat?
    /// A brief word about the last action — over the picture, not in the footer, where it would push
    /// the buttons out of the way on a phone.
    @State private var notice: String?
    #if os(iOS)
    /// Where `Share` reads from: the bytes of the current page, written once, on demand.
    @State private var sharedFile: URL?
    /// How far the viewer has been pulled down under the finger, in points — swipe-to-dismiss.
    /// Zero unless a downward drag is under way, and back to zero the moment it ends.
    @State private var pull: CGFloat = 0
    /// True once the drag in progress has proved itself a downward swipe. A drag that has not
    /// claimed the gesture moves nothing: the horizontal page turn still belongs to the pager.
    @State private var pulling = false
    #endif
    #if os(macOS)
    /// Arrow keys are the Mac's swipe. Focus is taken when the viewer opens, so the keys land here
    /// and not on a control behind it — and a focused text field anywhere else keeps its own arrows.
    @FocusState private var keyboardFocused: Bool
    #endif

    /// One picture, under its own name. Every transcript used this before a message could carry more.
    public init(data: Data, title: String, canExport: Bool = true, onClose: @escaping () -> Void) {
        self.init(items: [Item(data: data, name: title)], canExport: canExport, onClose: onClose)
    }

    /// Every picture that came with one message, opening at the one that was tapped.
    public init(items: [Item], startIndex: Int = 0, canExport: Bool = true, onClose: @escaping () -> Void) {
        self.items = items
        self.canExport = canExport
        self.onClose = onClose
        // A stale index from a message that changed underneath us opens the nearest picture
        // rather than nothing at all.
        let opening = items.isEmpty ? 0 : min(max(startIndex, 0), items.count - 1)
        _index = State(initialValue: opening)
    }

    /// The bytes on screen. Kept as the viewer's public face so a caller holding an `ImageViewer`
    /// reads what is drawn, not what it was made with.
    public var data: Data { current?.data ?? Data() }
    /// The name on screen.
    public var title: String { current?.name ?? "" }

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
        #if os(iOS)
        // Swipe down to put the picture away — the gesture every photo viewer on the phone has,
        // and the one the owner asked for ("let me close the gallery with a swipe down"). The
        // whole viewer follows the finger as one piece and thins a little as it goes, so the drag
        // uncovers what is behind the cover instead of sliding an unchanged screen.
        .offset(y: pull)
        .opacity(pullOpacity)
        .simultaneousGesture(dismissSwipe)
        // Nothing here opts out of the presentation's own drag, deliberately. The phone presents
        // this viewer in a `fullScreenCover` (`MobileTranscript`), which has no system drag of its
        // own for this gesture to fight — and the house rule is that no sheet in either app refuses
        // the drag (pinned by `test_approvals_and_sheets`). Because the gesture is *simultaneous*
        // rather than high-priority, a presentation that does have a drag keeps it.
        #endif
        .onChange(of: index) { _, _ in
            // A page opens fit — the zoom of the last picture would crop this one — and Share must
            // follow the page, or it hands over the bytes the previous picture wrote.
            zoom = 1
            pinchBase = nil
            #if os(iOS)
            sharedFile = nil
            #endif
        }
        #if os(macOS)
        .focusable()
        .focused($keyboardFocused)
        .hermeyFocusQuiet()
        .onAppear {
            keyboardFocused = true
            // The focus a window takes on its first layout pass can be dropped again a runloop
            // later; asking twice is what makes the arrows work without a click first.
            DispatchQueue.main.async { keyboardFocused = true }
        }
        .onKeyPress(.leftArrow, phases: .down) { _ in
            guard canPage, index > 0 else { return .ignored }
            index -= 1
            return .handled
        }
        .onKeyPress(.rightArrow, phases: .down) { _ in
            guard canPage, index < items.count - 1 else { return .ignored }
            index += 1
            return .handled
        }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image viewer: \(title)")
    }

    // MARK: The gallery

    private var current: Item? {
        guard !items.isEmpty else { return nil }
        return items[min(max(index, 0), items.count - 1)]
    }

    private var canPage: Bool { items.count > 1 }

    /// "2 of 5": the one fact a gallery owes the reader, on both platforms.
    private var counter: String { "\(index + 1) of \(items.count)" }

    private func step(_ delta: Int) {
        guard canPage else { return }
        index = min(max(index + delta, 0), items.count - 1)
    }

    /// Every picture, one at a time.
    ///
    /// Nothing is decoded up front: the phone's `TabView` holds the page on screen and its immediate
    /// neighbours and decodes each one as it comes into view; the Mac draws only the current page.
    @ViewBuilder
    private func pages(size: CGSize) -> some View {
        #if os(iOS)
        if canPage {
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                    page(item, size: size)
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // VoiceOver's swipe is the rotor's, not the pager's: the pages need a named action.
            .accessibilityAction(named: "Next image") { step(1) }
            .accessibilityAction(named: "Previous image") { step(-1) }
        } else if let item = current {
            page(item, size: size)
        }
        #else
        if let item = current {
            page(item, size: size)
                // A fresh identity per picture: the zoom of the last one is not this one's.
                .id(item.id)
        }
        #endif
    }

    @ViewBuilder
    private func page(_ item: Item, size: CGSize) -> some View {
        ZStack {
            Tokens.frame
            if let image = Self.image(from: item.data) {
                image
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(zoom, anchor: .center)
                    .frame(width: size.width, height: size.height)
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
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityLabel("The image \(item.name)")
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
            if canPage {
                // Where you are in the message's pictures, next to the name of the one you are on.
                Text(counter)
                    .font(.system(size: TypeScale.label, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Tokens.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Tokens.control, in: Capsule())
                    .fixedSize()
                    .accessibilityLabel("Image \(index + 1) of \(items.count)")
            }
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Tokens.textSecondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .hermeyFocusQuiet()
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
                pages(size: geometry.size)
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
        }
    }

    private var footer: some View {
        HStack(spacing: Self.footerGap) {
            #if os(macOS)
            pageControls
            #endif
            zoomControls
            Spacer(minLength: 4)
            exportControls
            HermeyButton("Done", kind: .primary, size: .small) { onClose() }
                .fixedSize()
                .layoutPriority(2)
        }
        .padding(.horizontal, Self.footerPadding)
        .padding(.vertical, 9)
    }

    #if os(macOS)
    /// The Mac has no swipe: the same pages, with buttons beside the arrow keys.
    @ViewBuilder
    private var pageControls: some View {
        if canPage {
            iconButton("chevron.left", enabled: index > 0, label: "Previous image") { step(-1) }
            iconButton("chevron.right", enabled: index < items.count - 1, label: "Next image") { step(1) }
        }
    }
    #endif

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
                .hermeyFocusQuiet()
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
                .hermeyFocusQuiet()
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
                .hermeyFocusQuiet()
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
        .hermeyFocusQuiet()
        #if os(macOS)
        .help(label)
        #endif
        .accessibilityLabel(label)
    }

    // MARK: Gestures

    /// Pinch to zoom the page on screen. The phone's pager is a `TabView` page swipe, which is a
    /// different gesture: this one stays on the picture and never fights the page turn.
    private var pinch: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let base = pinchBase ?? zoom
                if pinchBase == nil { pinchBase = base }
                zoom = min(4, max(1, base * value))
            }
            .onEnded { _ in pinchBase = nil }
    }

    #if os(iOS)
    /// Swipe down to put the gallery away.
    ///
    /// It runs *beside* the pager rather than over it: `simultaneousGesture` leaves the `TabView`'s
    /// page turn alone and `isDownward` decides which of the two a drag is, so a horizontal swipe is
    /// never claimed and still turns the page. A pinch is two fingers and no translation, so it
    /// never starts this either.
    ///
    /// Letting go decides: far enough down, or a shorter drag with the momentum to carry on, and the
    /// viewer closes through the same `onClose` as Close and Done; anything less springs back.
    private var dismissSwipe: some Gesture {
        DragGesture(minimumDistance: Self.dismissDragArm)
            .onChanged { value in
                if !pulling {
                    // The first samples of a horizontal swipe carry a little height too: nothing
                    // moves until the drag is downward by a clear margin.
                    guard Self.isDownward(value) else { return }
                    pulling = true
                }
                pull = max(0, value.translation.height)
            }
            .onEnded { value in
                let wasPulling = pulling
                pulling = false
                guard wasPulling else { return }
                let tossed = value.translation.height > Self.dismissThreshold
                    || value.predictedEndTranslation.height > Self.dismissFlick
                if tossed {
                    // Cleared before the cover goes: a spring-back must never run against a view
                    // that is already leaving.
                    pull = 0
                    onClose()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { pull = 0 }
                }
            }
    }

    /// A drag that is predominantly vertical, and downward. The margin on the width is what keeps a
    /// slightly-diagonal page turn from being taken for a dismissal.
    private static func isDownward(_ value: DragGesture.Value) -> Bool {
        let dy = value.translation.height
        return dy > 0 && dy > abs(value.translation.width) * 1.4
    }

    /// How much of the viewer is left as it is pulled away: it thins with the drag, far short of
    /// invisible — a picture that fades out under the finger reads as broken, not dismissed.
    private var pullOpacity: Double {
        1 - min(Double(pull) / 520, 0.55)
    }

    /// A tap and a small slip stay taps: the drag must travel before it can mean anything.
    private static let dismissDragArm: CGFloat = 12
    /// Far enough down that letting go puts the picture away…
    private static let dismissThreshold: CGFloat = 90
    /// …or a shorter drag travelling fast enough to carry on. The same pair the house
    /// swipe-to-dismiss uses (`SheetLanguage`), so both gestures let go at the same point.
    private static let dismissFlick: CGFloat = 160
    #endif

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
