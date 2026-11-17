import Foundation
import SwiftUI

/// A file link from the bots' shared tailnet file store, ready to draw as a card.
///
/// The store serves `https://hermes.corvus-vibes.ts.net:9446/<bot>/<file>` and the DNS-free
/// `http://100.86.19.1:8099/<bot>/<file>`. Both are recognised so a link Mo pastes from a script and
/// one a bot writes in chat get the same treatment. Nothing else is turned into a card: a random
/// `https://` link keeps the normal markdown link the renderer already draws.
public struct HermesFileLink: Identifiable, Equatable, Sendable {
    public let url: URL
    public let filename: String
    public let owner: String

    public var id: String { url.absoluteString }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              host == "hermes.corvus-vibes.ts.net" || host == "100.86.19.1" else {
            return nil
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, let name = parts.last?.removingPercentEncoding, !name.isEmpty else {
            return nil
        }
        self.url = url
        self.filename = name
        self.owner = parts[parts.count - 2]
    }

    /// The system glyph for this file's kind. Extension-only — a file name is all the store gives us,
    /// and guessing at a MIME type from a HEAD request would be a network call per row in a transcript.
    public var systemImage: String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.text.image"
        case "doc", "docx", "rtf", "txt", "md": return "doc.text"
        case "xls", "xlsx", "csv", "numbers": return "tablecells"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg": return "photo"
        case "zip", "tar", "gz", "7z": return "doc.zipper"
        case "mp3", "wav", "m4a", "flac": return "waveform"
        case "mp4", "mov", "m4v": return "film"
        case "py", "js", "swift", "json", "yaml", "yml", "sh": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

/// Detection and text cleanup for the shared file store.
public enum HermesFileLinks {
    /// Matches the store's two hosts with the `<bot>/<file>` path. Kept narrow on purpose.
    private static let pattern = #"https?://(?:hermes\.corvus-vibes\.ts\.net(?::9446)?|100\.86\.19\.1(?::8099)?)/(?:[A-Za-z0-9._~%+\-]+/)+[A-Za-z0-9._~%+\-]+(?:\?[A-Za-z0-9._~%+\-=&]*)?"#

    private static let regex: NSRegularExpression? = try? NSRegularExpression(pattern: pattern)

    /// Files mentioned in one message, in reading order, with duplicates removed.
    public static func find(in text: String) -> [HermesFileLink] {
        guard let regex else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var links: [HermesFileLink] = []
        for match in regex.matches(in: text, range: range) {
            guard let piece = Range(match.range, in: text),
                  let url = URL(string: String(text[piece])),
                  let link = HermesFileLink(url: url), !links.contains(link) else { continue }
            links.append(link)
        }
        return links
    }

    /// The message with file URLs taken out, so the card *replaces* the bare link rather than sitting
    /// underneath a second, ugly copy of it. A `[label](url)` whole link goes too — leaving `[]()`
    /// behind would look worse than the URL it replaced.
    public static func removingLinks(from text: String) -> String {
        guard let regex else { return text }
        var result = text
        let markdown = #"\[[^\]\n]*\]\("# + pattern + #"\)"#
        if let wrapper = try? NSRegularExpression(pattern: markdown) {
            result = wrapper.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        result = regex.stringByReplacingMatches(in: result,
                                                range: NSRange(result.startIndex..., in: result),
                                                withTemplate: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A downloadable file, drawn as a card instead of a naked URL.
public struct HermesFileLinkCard: View {
    public let link: HermesFileLink

    @Environment(\.openURL) private var openURL
    @State private var copied = false
    @State private var preparing = false
    @State private var shareError: String?
    #if os(iOS)
    @State private var sharedFile: HermesSharedFile?
    #endif

    public init(link: HermesFileLink) {
        self.link = link
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: link.systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Tokens.accentText)
                .frame(width: 32, height: 32)
                .background(Tokens.controlActive.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(link.filename)
                    .font(TypeScale.font(TypeScale.sm, weight: .medium))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(2)
                Text("From \(link.owner) · shared file")
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Button {
                copyLink()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy the download link")

            #if os(macOS)
            ShareLink(item: link.url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.textSecondary)
                    .frame(width: 26, height: 26)
            }
            #else
            // A URL on the pasteboard has no "Save to Files": iOS only offers that for a file on
            // disk. Fetch the bytes first, hand the system a real file, and the option appears.
            Button { Task { await prepareShare() } } label: {
                Group {
                    if preparing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .foregroundStyle(Tokens.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(preparing)
            .accessibilityLabel("Download and share this file")
            #endif
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Tokens.control)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Tokens.borderStrong, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { openURL(link.url) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("File: \(link.filename). Tap to download.")
        #if os(iOS)
        .sheet(item: $sharedFile) { file in
            HermesFileShareSheet(url: file.url)
        }
        #endif
        .alert("Could not download the file", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareError ?? "")
        }
    }

    #if os(iOS)
    /// The DNS-free address is plain HTTP, which the app cannot fetch under ATS. The same store is
    /// served over TLS on the tailnet name, so prefer that form for the app's own download.
    private func downloadURL() -> URL {
        var components = URLComponents(url: link.url, resolvingAgainstBaseURL: false) ?? link.url
        if components.host == "100.86.19.1" {
            components.host = "hermes.corvus-vibes.ts.net"
            components.port = 9446
            components.scheme = "https"
        }
        return components.url ?? link.url
    }

    private func prepareShare() async {
        preparing = true
        defer { preparing = false }
        do {
            let (temporary, response) = try await URLSession.shared.download(from: downloadURL())
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw FileShareError.badResponse
            }
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let folder = caches.appendingPathComponent("hermey-shares", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(link.filename)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            sharedFile = HermesSharedFile(url: destination)
        } catch {
            shareError = error.localizedDescription
        }
    }
    #endif

    private func copyLink() {
        #if os(iOS)
        UIPasteboard.general.string = link.url.absoluteString
        #else
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link.url.absoluteString, forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

private enum FileShareError: LocalizedError {
    case badResponse

    var errorDescription: String? {
        switch self {
        case .badResponse: return "The file store did not return the file."
        }
    }
}
