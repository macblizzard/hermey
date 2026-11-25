import Foundation

/// Where a message stops being a message and becomes a wall.
///
/// A log, a tool result, or — the report of 2026-11-25 — a reply whose every identifier is inline
/// code is drawn the ordinary way by parsing its markdown and styling every span: three hundred
/// `AttributedString` runs inside one `Text`, measured in full on the main thread whether the row is
/// on screen or not. That is what froze the phone while scrolling past it, and it is why a bubble of
/// ordinary length but *dense* inline code gets stuck in exactly the place a 20,000-character log
/// does.
///
/// So a body over the threshold is drawn as a **preview**: the first fifty lines, plain text, no
/// markdown, no spans, no table measurement, no unbounded `fixedSize`. The stored text is untouched —
/// the clamp is a drawing decision, and "Show full message" reveals the rest on demand.
///
/// Three numbers, and they are here and nowhere else, so the two shells and the tests cannot
/// disagree about which row is long. `Preview` is plain data and this module cannot parse markdown at
/// all: `HermesKit` has no dependency on `HermesRender`, so the collapsed path *cannot* reach the
/// parser — the module boundary is the proof, not a comment.
public enum TranscriptClamp {

    // MARK: - The numbers

    /// Fifty lines of body. The owner's number, and the number the button promises: a message that
    /// needs more than a screen and a half is being read as a document, and a document belongs
    /// behind a button.
    ///
    /// "Lines" are the body's own lines — the newlines the message was written with — and not the
    /// lines it happens to wrap to. Counting wrapped lines means measuring the text in the reader's
    /// font on the main thread, which is the expense this clamp exists to remove; a message is long
    /// because of what is in it, not because of the window it was read in.
    public static let maxBodyLines = 50

    /// ...or this many characters. Fifty *short* lines are not the problem, but one line can be: a
    /// single 6,000-character paragraph measures as one enormous line, and the span count below only
    /// catches the code-dense version of it.
    ///
    /// This is also the preview's own budget. Trigger and budget are the same number on purpose: a
    /// body that only just crosses the line loses almost nothing to the button, so the clamp cannot
    /// be an unpleasant surprise. Four thousand characters is about fifty lines at the chat measure;
    /// past that the character rule is what bounds a row that has no line breaks to count.
    public static let maxBodyCharacters = 4_000

    /// ...or this many inline-code spans. This is the number from the screenshots: a reply that names
    /// `display_order`, `live_message_count`, `test_the_per_chat_cap_is_raised` and
    /// `cargo test --bin hermeyd` in every sentence is under 1,500 characters and under 50 lines, and
    /// used to be parsed and styled as one run per identifier.
    ///
    /// Forty is not a false positive for ordinary writing. A normal answer bolds a phrase and
    /// backticks two or three identifiers; forty *closed* code spans in one message is a technical
    /// dump. Such a body is shown collapsed even when all of it fits in the preview — the count
    /// beside the button is then absent, because nothing is hidden — and opening it draws the
    /// markdown the message was written in. That is the trade: dense styling costs the reader one
    /// tap, not a frozen scroll.
    public static let maxBodyInlineSpans = 40

    /// What the collapsed row draws: the first fifty lines, cut at the character budget.
    public static var previewLines: Int { maxBodyLines }
    public static var previewCharacters: Int { maxBodyCharacters }

    /// The one word an expanded row's button says. The short form of the collapse, as asked for: no
    /// count beside it, because nothing is hidden any more.
    public static let showLessTitle = "Show less"

    // MARK: - What a body is

    /// A message as the shells hand it to the clamp: the text that will be drawn, and the kinds of
    /// the `::card` markers that were taken out of it.
    ///
    /// `text` is the *body* — markers already stripped, because a marker line is drawn as a card and
    /// is not text. `cardKinds` is what is left under the prose.
    public struct Body: Sendable, Equatable {
        public let text: String
        public let cardKinds: [String]

        public init(text: String, cardKinds: [String] = []) {
            self.text = text
            self.cardKinds = cardKinds
        }
    }

    /// What to draw: the whole body, or a preview of it.
    public enum Plan: Equatable, Sendable {
        case whole
        case preview(Preview)
    }

    /// A body that is too long, cut down to what the collapsed row draws.
    public struct Preview: Equatable, Sendable {
        /// The first lines of the body, plain text. Markdown delimiters are left exactly as they were
        /// written: the backticks around an identifier are the only cue that it is code, they cost
        /// nothing to draw, and removing them would be the app editing the message. A single line
        /// longer than the budget ends in an ellipsis, because it was cut.
        public let text: String
        /// Lines drawn — whole ones, plus the cut one, if the first line alone was over budget.
        public let shownLines: Int
        /// Lines of the actual body that are not fully shown. A line cut by the character budget
        /// counts as hidden, because its tail is: that is why a one-line giant says "1 more line".
        public let hiddenLines: Int
        /// Every line the body has, counted from the body itself — so the count stays right when a
        /// row is re-measured after a resize, a font step or a re-render.
        public let totalLines: Int
        /// What the body tripped on, for the tests and for Instruments.
        public let reason: Reason

        public enum Reason: String, Sendable, Equatable {
            case lines, characters, inlineCode
        }

        /// The cost of the collapsed row, stated so a test can hold it: characters drawn, lines
        /// drawn, and spans styled — which is zero, by construction.
        public var characters: Int { text.count }
        public var spansStyled: Int { 0 }
    }

    // MARK: - The decision

    /// What this body should be drawn as. The one call both shells and every row kind make.
    ///
    /// The exemption is here rather than in a view so neither shell can invent one: a message may
    /// skip the clamp only when it has **no prose of its own** and every card it names is one of the
    /// few that cannot be large (see `smallStructuredCards`). A `::blocks` board, an A2UI surface, a
    /// delegation row and a tool-run row all go through the same door.
    public static func plan(_ body: Body) -> Plan {
        if isOnlySmallStructuredCards(body) { return .whole }
        guard let preview = preview(body.text) else { return .whole }
        return .preview(preview)
    }

    /// Every card kind that may skip the clamp, and the reason each one is on the list.
    ///
    /// These are *structured*: the renderer draws a fixed set of rows, a picture, or a handful of
    /// fields, and the wire format caps them. None of them can arrive as a wall of text, so clamping
    /// one would only take away the form the reader was asked to fill in. Anything not named here — a
    /// `::blocks` board, an A2UI surface, a card kind added tomorrow — is clamped when it is long,
    /// because "cannot be large" is not something a new kind may simply assume.
    ///
    /// - `approval`: one request, one set of buttons — the engine writes it, and it is a question,
    ///   never a transcript.
    /// - `draft-email`: a short subject and body, drawn in fields the person edits and sends.
    /// - `infographic`: one picture and a few label/value rows; the picture is the size.
    /// - `secure-entry`: a credential form — a handful of inputs, never a body of prose.
    public static let smallStructuredCards: Set<String> = [
        "approval", "draft-email", "infographic", "secure-entry",
    ]

    public static func isSmallStructuredCard(_ kind: String) -> Bool {
        smallStructuredCards.contains(kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// A message whose only body is one of those cards.
    public static func isOnlySmallStructuredCards(_ body: Body) -> Bool {
        guard !body.cardKinds.isEmpty else { return false }
        guard body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return body.cardKinds.allSatisfy(isSmallStructuredCard)
    }

    // MARK: - The measurement

    /// Whether this body is long enough to take the preview path.
    ///
    /// Bounded work on purpose, because it is called from a view body on every pass: it stops at
    /// `maxBodyCharacters + 1` characters, at the fifty-first line, or at the forty-first code span,
    /// whichever comes first. A body under every budget is scanned entirely, so the answer is exact.
    public static func isLong(_ text: String) -> Bool {
        measure(text).isLong
    }

    /// The first `previewLines` whole lines of `text` and how many lines were left behind.
    ///
    /// - Returns: `nil` when the body is short enough to draw whole, so a caller can use
    ///   `if let preview = TranscriptClamp.preview(text)` as the whole branch condition.
    public static func preview(_ text: String) -> Preview? {
        let measured = measure(text)
        guard measured.isLong, let reason = measured.reason else { return nil }

        // Split the way `CardMarker.scan` does: Swift treats "\r\n" as one Character, so
        // `split(separator: "\n")` never breaks a CRLF message and every line would look like one
        // enormous one. `components(separatedBy:)` breaks both.
        let lines = text.components(separatedBy: "\n")
        var drawn: [String] = []
        var used = 0
        var whole = 0
        var index = 0
        while index < lines.count, drawn.count < previewLines {
            let line = lines[index]
            let cost = drawn.isEmpty ? line.count : line.count + 1     // the newline
            if used + cost <= previewCharacters {
                drawn.append(line)
                used += cost
                whole += 1
                index += 1
                continue
            }
            if drawn.isEmpty {
                // Not even one line fits — one line can be longer than the whole budget, and drawing
                // nothing at all would look like an empty message. Its tail is hidden, so it counts
                // as hidden even though its head is drawn.
                drawn.append(truncated(line, at: previewCharacters))
            }
            // Either the first line was cut or the budget is spent: nothing after it can be drawn.
            break
        }

        return Preview(text: drawn.joined(separator: "\n"),
                       shownLines: drawn.count,
                       hiddenLines: max(0, lines.count - whole),
                       totalLines: lines.count,
                       reason: reason)
    }

    /// "Show full message · 312 more lines" — the affordance's own words, decided once.
    ///
    /// The count is the body's, not a constant: it is recomputed from the text every time the row is
    /// drawn, so resizing the window, changing the text size or re-rendering the row cannot leave a
    /// stale number beside the button. A body that fits the preview but was collapsed for its span
    /// density has nothing hidden, and then the button says only what it does.
    public static func showFullTitle(hiddenLines: Int) -> String {
        hiddenLines > 0
            ? "Show full message · \(hiddenLines) more line\(hiddenLines == 1 ? "" : "s")"
            : "Show full message"
    }

    // MARK: - Counting

    /// How many inline code spans the body contains.
    ///
    /// A delimiter count, not a parse: backtick runs are paired off, so `` `a` `b` `c` `` is three.
    /// Stray backticks over-count, which is the safe direction — a body with forty of them is dense
    /// whether or not they all close — and nothing here walks emphasis, links or escapes, because
    /// that would be the markdown parse this path exists to avoid.
    public static func inlineCodeSpanCount(in text: String) -> Int {
        var runs = 0
        var previousWasBacktick = false
        for character in text {
            if character == "`" {
                if !previousWasBacktick { runs += 1 }
                previousWasBacktick = true
            } else {
                previousWasBacktick = false
            }
        }
        return runs / 2
    }

    /// One bounded pass: characters, lines and code spans, stopping at the first budget it breaks.
    struct Measurement: Equatable, Sendable {
        var characters = 0
        /// The first line exists before any line break does, so an empty body is one line.
        var lines = 1
        var spans = 0
        var reason: Preview.Reason?
        var isLong: Bool { reason != nil }
    }

    static func measure(_ text: String) -> Measurement {
        var measured = Measurement()
        guard !text.isEmpty else { return measured }
        var runs = 0
        var previousWasBacktick = false
        for character in text {
            measured.characters += 1
            if character == "\n" { measured.lines += 1 }
            if character == "`" {
                if !previousWasBacktick {
                    runs += 1
                    // A span is complete when its closing run is: two runs, one span.
                    if runs % 2 == 0 {
                        measured.spans += 1
                        if measured.spans > maxBodyInlineSpans {
                            measured.reason = .inlineCode
                            return measured
                        }
                    }
                }
                previousWasBacktick = true
            } else {
                previousWasBacktick = false
            }
            if measured.characters > maxBodyCharacters {
                measured.reason = .characters
                return measured
            }
            if measured.lines > maxBodyLines {
                measured.reason = .lines
                return measured
            }
        }
        return measured
    }

    /// Cut a single line down to `budget` characters, on a word boundary when there is one near the
    /// end, and say so with an ellipsis: a preview that stops mid-identifier reads as a message that
    /// was never finished.
    static func truncated(_ line: String, at budget: Int) -> String {
        guard line.count > budget else { return line }
        let prefix = line.prefix(budget)
        if let space = prefix.lastIndex(of: " "),
           prefix.distance(from: prefix.startIndex, to: space) > budget / 2 {
            return String(prefix[..<space]) + "…"
        }
        return String(prefix) + "…"
    }
}
