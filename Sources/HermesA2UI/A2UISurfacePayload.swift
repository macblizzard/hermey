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
    /// The marker that starts a surface: `::a2ui{` at a line start or after whitespace.
    static let pattern = #"::a2ui(\{(?:[^{}]|\{[^{}]*\})*\})"#

    /// Every surface in a reply, in order. A marker that is not valid JSON is skipped rather than
    /// thrown: one malformed surface must not cost the message its text.
    public static func surfaces(in text: String) -> [A2UISurfacePayload] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let jsonRange = Range(match.range(at: 1), in: text) else { return nil }
            return decode(String(text[jsonRange]))
        }
    }

    /// The reply with its surface markers removed — what a bubble shows above the drawn surface.
    public static func textWithoutMarkers(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        // A marker sat on its own line, so removing it leaves a blank line and a gap of two or
        // three where the reply had one paragraph break. Squeeze the runs down to one.
        var kept: [String] = []
        for line in stripped.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty, kept.last?.isEmpty ?? true { continue }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
