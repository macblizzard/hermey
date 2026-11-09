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
    /// `entries` without the tool cards, when the user asked for no tool calls.
    public static func rows(_ entries: [TranscriptEntry], showToolCalls: Bool) -> [TranscriptEntry] {
        guard !showToolCalls else { return entries }
        return entries.filter { $0.role != .tool }
    }

    /// Whether the running turn has any card to draw.
    public static func showsLiveCards(showToolCalls: Bool, hasLiveTools: Bool) -> Bool {
        showToolCalls && hasLiveTools
    }
}
