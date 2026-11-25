import Foundation

/// Where a message stops being a message and becomes a log.
///
/// A tool result or a pasted log can be tens of thousands of characters. Drawn the ordinary way it
/// is measured in full on the main thread: the markdown is parsed into blocks, every table is
/// measured, and the whole thing becomes one enormous view that SwiftUI has to lay out whether it
/// is on screen or not. The owner's report of the scroll freeze was "got stuck again after scrolling
/// past the long log" — the row count was only half of it; one 20,000-character row is enough to
/// freeze the phone on its own.
///
/// So a message over the threshold is drawn as a **preview**: whole lines, plain text, no markdown,
/// no table measurement, no unbounded `fixedSize`. The stored text is untouched — the clamp is a
/// drawing decision, and "Show full message" reveals the rest, once, on demand.
///
/// The numbers are here and nowhere else, so the two shells and the tests cannot disagree about
/// which row is long.
public enum TranscriptClamp {
    /// Long by character count...
    public static let maxPreviewCharacters = 4_000
    /// ...or by line count, whichever comes first: sixty 40-character lines is a log, not a message.
    public static let maxPreviewLines = 60

    /// What the collapsed row draws: whole lines, so the preview never ends mid-word.
    public static let previewCharacters = 1_600
    public static let previewLines = 24

    /// Whether this row should be drawn as a preview.
    ///
    /// Bounded work on purpose: it scans at most `maxPreviewCharacters + 1` characters and at most
    /// `maxPreviewLines` newlines, because it is called from a view body on every pass. A text under
    /// the character cap is scanned entirely, so the line rule is exact for short rows, and a text
    /// over it is long by the character rule without needing its lines counted at all.
    public static func isLong(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var seen = 0
        // Lines, not newlines: the first line exists before any line break does, and 60 lines is
        // the threshold — the sixty-first line is what makes it a log.
        var lines = 1
        for character in text {
            seen += 1
            if seen > maxPreviewCharacters { return true }
            if character == "\n" {
                lines += 1
                if lines > maxPreviewLines { return true }
            }
        }
        return false
    }

    /// The first `previewLines` whole lines of `text`, and how many lines were left behind.
    ///
    /// - Returns: `nil` when the text is short enough to draw whole, so a caller can use
    ///   `if let preview = TranscriptClamp.preview(...)` as the whole branch condition.
    public static func preview(_ text: String) -> (text: String, hiddenLines: Int)? {
        guard isLong(text) else { return nil }
        var out = ""
        var lines = 0
        var hidden = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if lines >= previewLines || out.count + line.count > previewCharacters {
                hidden += 1
                continue
            }
            if !out.isEmpty { out += "\n" }
            out += line
            lines += 1
        }
        return (out, hidden)
    }

    /// "Show 412 more lines" / "Show the rest" — the affordance's own words, decided once.
    public static func showFullTitle(hiddenLines: Int) -> String {
        hiddenLines > 0
            ? "Show full message · \(hiddenLines) more line\(hiddenLines == 1 ? "" : "s")"
            : "Show full message"
    }
}
