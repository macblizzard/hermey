import Foundation

/// One `::card{…}` line in a reply: the three facts a client needs to fetch and draw the card.
///
/// The `agent-cards` skill writes the card beside the chat and puts one directive line in the
/// message:
///
///     ::card{id="c-9b" kind="approval" file="cards/c-9b.json"}
///
/// The line is data, never code: `file` is relative to the session's working directory and the
/// engine resolves it, so the client only carries the three strings.
public struct CardRef: Sendable, Equatable, Hashable {
    /// The card's id, the same shape the fetch route accepts (`^[A-Za-z0-9_-]{1,40}$`).
    public let id: String
    /// The kind the marker claims. Kept as text: the file is authoritative, and an unknown kind
    /// degrades to "Card not available" instead of making the marker disappear.
    public let kind: String
    /// The path relative to the session's working directory, e.g. `cards/c-9b.json`.
    public let file: String

    public init(id: String, kind: String, file: String) {
        self.id = id
        self.kind = kind
        self.file = file
    }
}

/// The result of scanning a reply: the prose a bubble shows, and the cards it names in order.
public struct CardScan: Sendable, Equatable {
    /// The reply with every valid marker line removed; every other line is untouched.
    public let prose: String
    /// Cards in the order their markers appear. Empty for a reply with no marker.
    public let refs: [CardRef]

    public init(prose: String, refs: [CardRef]) {
        self.prose = prose
        self.refs = refs
    }
}

/// Finds `::card{…}` directive lines and takes them out of the prose.
///
/// Two rules from the contract decide whether a line is a card:
///
/// * the marker must be **alone** on its line — `Here: ::card{…}` is prose, because the skill
///   only ever emits the directive on a line of its own and eating a sentence would lose text;
/// * it must be **outside a fenced code block** — a reply that teaches the marker (this one does)
///   must keep its example, not draw it.
public enum CardMarker {
    /// `::card{id="…" kind="…" file="…"}`, whole line, no braces inside the attributes.
    private static let linePattern = #"^::card\{([^{}]*)\}$"#

    /// One `name="value"` or `name='value'` pair inside the braces.
    private static let attributePattern = #"([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#

    /// What the route will accept as an id. A marker whose id cannot be fetched is left as text:
    /// stripping it would hide a line and draw nothing.
    private static let idPattern = #"^[A-Za-z0-9_-]{1,40}$"#

    private static let lineRegex = try? NSRegularExpression(pattern: linePattern)
    private static let attributeRegex = try? NSRegularExpression(pattern: attributePattern)

    /// Every card marker in `text`, in the order it appears. Never throws.
    public static func references(in text: String) -> [CardRef] {
        scan(text).refs
    }

    /// The reply with its card marker lines removed, prose otherwise intact.
    public static func textWithoutMarkers(_ text: String) -> String {
        scan(text).prose
    }

    /// One pass over the reply: the prose to show and the cards to draw.
    public static func scan(_ text: String) -> CardScan {
        var refs: [CardRef] = []
        var kept: [String] = []
        var fence: Fence?

        // Split at the NSString level: `String.split(separator: "\n")` never breaks a CRLF message,
        // because Swift treats "\r\n" as a single Character. A trailing "\r" is dropped for matching
        // only and kept in the prose, which has to come back byte-identical.
        for raw in text.components(separatedBy: "\n") {
            let hadCarriageReturn = raw.hasSuffix("\r")
            let trimmed = (hadCarriageReturn ? String(raw.dropLast()) : raw)
                .trimmingCharacters(in: .whitespaces)

            if let open = fence {
                kept.append(raw)
                if closes(trimmed, open) { fence = nil }
                continue
            }

            if let open = openingFence(trimmed) {
                fence = open
                kept.append(raw)
                continue
            }

            if let ref = marker(in: trimmed) {
                refs.append(ref)
                continue
            }

            kept.append(raw)
        }

        return CardScan(prose: kept.joined(separator: "\n"), refs: refs)
    }

    // MARK: - A marker line

    /// The ref a line carries, or nil when the line is not a well-formed marker.
    private static func marker(in trimmed: String) -> CardRef? {
        guard let regex = lineRegex else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range), match.numberOfRanges > 1,
              let bodyRange = Range(match.range(at: 1), in: trimmed) else { return nil }

        var attributes: [String: String] = [:]
        let body = String(trimmed[bodyRange])
        if let attributeRegex = attributeRegex {
            let bodyNS = NSRange(body.startIndex..<body.endIndex, in: body)
            for attribute in attributeRegex.matches(in: body, range: bodyNS) {
                guard let nameRange = Range(attribute.range(at: 1), in: body) else { continue }
                let name = String(body[nameRange]).lowercased()
                // Two quote styles, so two value groups; exactly one of them matched.
                var value: String?
                for group in 2...3 where attribute.range(at: group).location != NSNotFound {
                    if let valueRange = Range(attribute.range(at: group), in: body) {
                        value = String(body[valueRange])
                    }
                }
                if let value = value { attributes[name] = value }
            }
        }

        guard let id = attributes["id"]?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
              id.range(of: idPattern, options: .regularExpression) != nil,
              let kind = attributes["kind"]?.trimmingCharacters(in: .whitespaces), !kind.isEmpty,
              let file = attributes["file"]?.trimmingCharacters(in: .whitespaces), !file.isEmpty
        else { return nil }

        return CardRef(id: id, kind: kind, file: file)
    }

    // MARK: - Fenced code blocks

    private struct Fence {
        let marker: Character
        let count: Int
    }

    /// A fence opens with at least three backticks or tildes at the start of a trimmed line; the
    /// rest of the line is an info string and does not matter here.
    private static func openingFence(_ trimmed: String) -> Fence? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        var count = 0
        for character in trimmed {
            guard character == first else { break }
            count += 1
        }
        return count >= 3 ? Fence(marker: first, count: count) : nil
    }

    /// A closing fence is only the marker character, at least as long as the one that opened it.
    private static func closes(_ trimmed: String, _ open: Fence) -> Bool {
        guard !trimmed.isEmpty else { return false }
        var count = 0
        for character in trimmed {
            guard character == open.marker else { return false }
            count += 1
        }
        return count >= open.count
    }
}
