import Foundation

/// One A2UI surface carried inline in a bot reply.
///
/// Hermes writes the compiled wire JSON as a single marker line:
///
///     ::a2ui{"surface":"928e1c18","messages":[{"version":"1.0","createSurface":{…}}]}
///
/// Keeping the surface in the message (rather than behind an id and a fetch) is what makes a
/// transcript self-describing: a thread reopened next month still draws, with no card session,
/// no bridge call and nothing to expire. The payload is validated A2UI JSON, never executable.
public struct A2UISurfacePayload: Sendable, Equatable {
    /// The producer's 8-hex id, for logs and for matching an action back to a surface.
    public let surface: String
    /// The raw wire messages, ready for `MessageProcessor`.
    public let messagesJSON: [String]

    public init(surface: String, messagesJSON: [String]) {
        self.surface = surface
        self.messagesJSON = messagesJSON
    }
}

public enum A2UIMarker {
    /// The marker that starts a surface.
    static let prefix = "::a2ui"

    /// Every surface in a reply, in order. A marker whose JSON cannot be read is skipped rather
    /// than thrown: one malformed surface must not cost the message its text.
    public static func surfaces(in text: String) -> [A2UISurfacePayload] {
        spans(in: text).compactMap { decode($0.json) }
    }

    /// The reply with its surface markers removed — what a bubble shows above the drawn surface.
    public static func textWithoutMarkers(_ text: String) -> String {
        var result = text
        for span in spans(in: text).reversed() {
            result.removeSubrange(span.whole)
        }
        // A marker sat on its own line, so removing it leaves a blank line and a gap of two or
        // three where the reply had one paragraph break. Squeeze the runs down to one.
        var kept: [String] = []
        for line in result.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty, kept.last?.isEmpty ?? true { continue }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Span {
        let whole: Range<String.Index>  // the ::a2ui{…} text, removed from the bubble
        let json: String                // the {…} object, braces included
    }

    /// Every well-formed marker: `::a2ui` immediately followed by a brace-balanced JSON object.
    ///
    /// A regex cannot do this: a real surface nests object inside array inside object, and any
    /// fixed-depth pattern either misses markers or eats the prose after them. So the scanner
    /// walks the text once, honouring string literals and escapes, and stops at the brace that
    /// closes the object it started.
    static func spans(in text: String) -> [Span] {
        var found: [Span] = []
        var cursor = text.startIndex
        while let hit = text.range(of: prefix, range: cursor..<text.endIndex) {
            let opener = text.index(hit.lowerBound, offsetBy: prefix.count)
            guard opener < text.endIndex, text[opener] == "{",
                  let closer = closingBrace(in: text, from: opener) else {
                cursor = hit.upperBound
                continue
            }
            let end = text.index(after: closer)
            found.append(Span(whole: hit.lowerBound..<end, json: String(text[opener..<end])))
            cursor = end
        }
        return found
    }

    /// The index of the brace that closes the object starting at `start`, or nil if unbalanced.
    static func closingBrace(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return index }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// `{ "surface": …, "messages": [ … ] }` → a payload; nil for anything else.
    static func decode(_ json: String) -> A2UISurfacePayload? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = root["messages"] as? [Any], !messages.isEmpty else { return nil }
        let encoded = messages.compactMap { message -> String? in
            guard let messageData = try? JSONSerialization.data(withJSONObject: message) else { return nil }
            return String(data: messageData, encoding: .utf8)
        }
        guard !encoded.isEmpty else { return nil }
        let identifier = root["surface"] as? String ?? ""
        return A2UISurfacePayload(surface: identifier, messagesJSON: encoded)
    }
}
