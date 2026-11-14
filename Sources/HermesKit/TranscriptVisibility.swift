import Foundation

/// What the chat draws, given the user's preference about tool calls.
///
/// The setting used to mean "show the *output* under each card": turning it off left every command
/// card in the transcript with its body collapsed, which the user reads as the switch doing nothing
/// at all — he turned tool calls off and tool calls are still there. Off now means the cards are not
/// rows of the conversation; the command still ran, its result is still in the host's transcript, and
/// turning the switch back on shows both again.
///
/// Pure and free-standing on purpose: both apps and the history path go through it, and it is the
/// one thing a test can pin without a socket, a model or SwiftUI.
public enum TranscriptVisibility {
    /// `entries` without the tool cards, when the user asked for no tool calls — and without the
    /// wordless assistant rows either way.
    ///
    /// `showReasoning` drops the reasoning rows too. It used to gate only the *live* block, and
    /// the client synthesises a reasoning row when a turn ends, so turning reasoning off hid the
    /// text while it streamed and left the same words in the history — the switch that looked
    /// broken (reported 2026-11-14: "reasoning disabled but it's still showing me reasoning").
    /// One rule for a row's visibility, both shells, no second filter in a view.
    public static func rows(_ entries: [TranscriptEntry],
                            showToolCalls: Bool,
                            showReasoning: Bool = true) -> [TranscriptEntry] {
        var kept = showToolCalls ? entries : entries.filter { $0.role != .tool }
        if !showReasoning { kept = kept.filter { $0.role != .reasoning } }
        return kept.filter { !isScaffold($0) }
    }

    /// An assistant row with no words and no pictures was never a message: the host writes one as a
    /// banner for the commands that follow it. With the cards hidden it renders as an empty bubble
    /// and a timestamp — "blank lines with timestamps" — and with them shown it is an empty bubble
    /// above its own cards. Neither is worth a row.
    static func isScaffold(_ entry: TranscriptEntry) -> Bool {
        guard entry.role == .assistant, entry.tool == nil, entry.attachments.isEmpty else { return false }
        return entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether two assistant texts are the same words, once whitespace is ignored.
    ///
    /// The host can send one paragraph as three separate events — the commentary sealed at a tool
    /// call, the same text as `message.interim`, and the answer at completion — and each used to get
    /// its own row. Within one turn, identical words are the same message.
    public static func saysTheSame(_ text: String, _ other: String?) -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return false }
        return words == (other ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the live bubble should print, given the last assistant row on screen.
    ///
    /// Kept for callers with a single row; `afterRows:` is the honest form — a turn can already own
    /// several rows (see `streamingRemainder(_:afterRows:)`).
    public static func streamingRemainder(_ streaming: String, afterRow row: String?) -> String {
        streamingRemainder(streaming, afterRows: row.map { [$0] } ?? [])
    }

    /// What the live bubble should print, given every assistant row THIS TURN already wrote.
    ///
    /// The host streams the whole message of the turn, while each paragraph it seals (at a tool
    /// call, or as `message.interim`) becomes a row with a time stamp of its own. Comparing only
    /// against the trailing row left the *earlier* paragraphs in the bubble: measured 2026-11-10, a
    /// turn whose bubble re-printed two rows that were already on screen above it — the same words
    /// twice, one copy with a caret. So every paragraph a row already says is dropped wherever it
    /// sits in the stream, and a paragraph whose sealed row is a prefix of it keeps only its tail.
    public static func streamingRemainder(_ streaming: String, afterRows rows: [String]) -> String {
        unsaid(streaming, by: rows)
    }

    /// The part of *text* that *rows* do not already say.
    ///
    /// Paragraphs are the unit: a sealed commentary is a paragraph, and the stream repeats it as a
    /// paragraph of the turn's message. A paragraph identical to a row is dropped; one that is still
    /// being re-streamed (a prefix of its row) is dropped too, because nothing new has arrived yet;
    /// one that continues its row keeps the continuation. Rows shorter than 20 characters are
    /// ignored — a short row ("Done.") is not a header for the next reply, and the old single-row
    /// rule said the same thing.
    public static func unsaid(_ text: String, by rows: [String]) -> String {
        let stream = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stream.isEmpty else { return "" }
        let said = rows.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 20 }
        guard !said.isEmpty else { return stream }
        let kept = splitParagraphs(stream).compactMap { paragraph -> String? in
            var remainder = paragraph
            for row in said {
                if remainder == row { return nil }
                if row.hasPrefix(remainder) { return nil }
                if remainder.hasPrefix(row) {
                    remainder = String(remainder.dropFirst(row.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return remainder.isEmpty ? nil : remainder
        }
        return kept.joined(separator: "\n\n")
    }

    /// Split on blank lines, which is how this app's markdown separates paragraphs. Runs of spaces
    /// inside a paragraph are irrelevant to "same words", so they are collapsed.
    static func splitParagraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Whether a row has anything to say, which is also the condition for showing its time.
    public static func hasContent(_ entry: TranscriptEntry) -> Bool {
        !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !entry.attachments.isEmpty
    }

    /// Whether the running turn has any card to draw.
    public static func showsLiveCards(showToolCalls: Bool, hasLiveTools: Bool) -> Bool {
        showToolCalls && hasLiveTools
    }
}
