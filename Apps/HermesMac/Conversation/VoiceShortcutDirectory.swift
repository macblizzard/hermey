import Foundation

/// The menu bar's way into the composer's one audio control.
///
/// **Why a request and not a reference.** The hands-free loop and the dictation recorder belong to
/// `MacComposerBar`: one microphone per conversation, wired to that conversation's host, torn down
/// with the bar. A menu item is not a view — it holds no bar — and a shared controller would be a
/// second owner of the same input device, which is the one thing the loop's design forbids. So the
/// two keys post a request, exactly as the Message Actions key does
/// (`MessageMenuDirectory.requestActions()`), and the bar that owns the microphone answers it by
/// running the same method its own gesture runs. There is no second start path.
///
/// Mac-only in effect: the phone has no keyboard, and reaches the same two methods through the
/// control's tap and hold.
enum VoiceShortcutDirectory {

    /// ⌥⌘V — open the voice conversation, or end the one that is running.
    static func requestConversationToggle() {
        NotificationCenter.default.post(name: .voiceConversationToggleRequested, object: nil)
    }

    /// ⌃⌘D — start a dictation, or stop the one recording and put its words in the draft.
    static func requestDictation() {
        NotificationCenter.default.post(name: .voiceDictationRequested, object: nil)
    }
}

extension Notification.Name {
    /// ⌥⌘V, from the Conversation menu. Posted by `VoiceShortcutDirectory.requestConversationToggle()`.
    static let voiceConversationToggleRequested = Notification.Name("hermey.voice.conversation.toggle")

    /// ⌃⌘D, from the same menu. Posted by `VoiceShortcutDirectory.requestDictation()`.
    static let voiceDictationRequested = Notification.Name("hermey.voice.dictate")
}
