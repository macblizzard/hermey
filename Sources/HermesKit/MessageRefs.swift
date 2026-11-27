import Foundation

/// The `@image:` / `@file:` lines the host puts into a stored user message.
///
/// When a picture is attached, the gateway rewrites it into a reference line and stores that as
/// part of the prompt — `@image:/home/agent/.hermes/profiles/assistant/images/upload_af01xgt9.png` — because
/// the agent needs a path to open. Sent back as a transcript row, those lines are host bookkeeping:
/// on screen they are an absolute path where a thumbnail belongs, and they also break the vault's
/// text matching, because the stored text no longer equals what the user typed.
///
/// The parse itself lives in `MessageAttachments.swift`, next to the attachment it produces: a
/// row needs more than the path (the type and size the `📎` block spells out), and two parsers for
/// one message shape is how the two shells drift apart.
public enum MessageRefs {

    /// The two markers a reference line can start with.
    static let markers = ["@image:", "@file:"]

    /// Splits a stored message into what the user wrote and the references the host added.
    public static func split(_ text: String) -> (body: String, refs: [String]) {
        let scan = attachments(in: text)
        return (scan.body, scan.attachments.map(\.path))
    }

    /// The message as the user would have written it.
    public static func display(_ text: String) -> String {
        let body = attachments(in: text).body
        // The host appends an attachment's extracted text under a `--- attachment:` line, after
        // whatever was typed — that block belongs to the prompt, not the bubble. Everything from
        // the first marker on is host-added, so the typed words are everything before it.
        if let marker = body.range(of: "--- attachment:") {
            return String(body[..<marker.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return body
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
