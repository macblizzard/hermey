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
    public static func rows(_ entries: [TranscriptEntry], showToolCalls: Bool) -> [TranscriptEntry] {
        let withoutCards = showToolCalls ? entries : entries.filter { $0.role != .tool }
        return withoutCards.filter { !isScaffold($0) }
    }

    /// An assistant row with no words and no pictures was never a message: the host writes one as a
    /// banner for the commands that follow it. With the cards hidden it renders as an empty bubble
    /// and a timestamp — "blank lines with timestamps" — and with them shown it is an empty bubble
    /// above its own cards. Neither is worth a row.
    static func isScaffold(_ entry: TranscriptEntry) -> Bool {
        guard entry.role == .assistant, entry.tool == nil, entry.attachments.isEmpty else { return false }
        return entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
