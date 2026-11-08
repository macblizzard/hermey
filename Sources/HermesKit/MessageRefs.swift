import Foundation

/// The `@image:` / `@file:` lines the host puts into a stored user message.
///
/// When a picture is attached, the gateway rewrites it into a reference line and stores that as
/// part of the prompt — `@image:/home/agent/.hermes/profiles/assistant/images/upload_af01xgt9.png` — because
/// the agent needs a path to open. Sent back as a transcript row, those lines are host bookkeeping:
/// on screen they are an absolute path where a thumbnail belongs, and they also break the vault's
/// text matching, because the stored text no longer equals what the user typed.
public enum MessageRefs {

    private static let markers = ["@image:", "@file:"]

    /// Splits a stored message into what the user wrote and the references the host added.
    public static func split(_ text: String) -> (body: String, refs: [String]) {
        var body: [String] = []
        var refs: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = markers.first(where: { trimmed.hasPrefix($0) }) {
                let path = String(trimmed.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespaces)
                if !path.isEmpty { refs.append(path) }
            } else {
                body.append(String(line))
            }
        }
        // The references were appended after the words, so what is left can end in blank lines.
        let joined = body.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (joined, refs)
    }

    /// The message as the user would have written it.
    public static func display(_ text: String) -> String {
        split(text).body
    }

    /// Just the file name of each reference — all a chat bubble should show when it has neither
    /// the picture nor the file.
    public static func names(_ refs: [String]) -> [String] {
        refs.map { path in
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? path : name
        }
    }
}
