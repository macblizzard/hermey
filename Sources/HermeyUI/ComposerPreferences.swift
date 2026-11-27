import Foundation

/// Composer preferences that both shells read by the same key.
public enum ComposerPreferences {
    /// Dismiss the keyboard when a message is sent.
    ///
    /// On by default: the composer's job ends when the message is in the transcript, and the keyboard
    /// covering half the conversation afterwards is what makes a phone chat feel stuck. One switch in
    /// Settings → Chat puts it back.
    public static let dismissKeyboardOnSendKey = "hermey.composer.dismissKeyboardOnSend"
    public static let defaultDismissKeyboardOnSend = true

    /// The composer's one audio control: a tap talks hands-free, a hold dictates. The line under
    /// the composer says so once per device and then never again — the key is written the first
    /// time the hint is dismissed *or* the control is used, so it cannot reappear after the lesson
    /// has landed.
    public static let voiceHintSeenKey = "hermey.composer.voiceHintSeen"
    public static let voiceHintText = "Tap to talk hands-free · hold to dictate"
    /// The named accessibility action that does what a hold does, for VoiceOver and the keyboard.
    public static let dictationActionName = "Dictate"
}

/// What the field should do after the draft is cleared underneath it.
///
/// The model owns the draft and clears it on send; the composer only binds to it. A focused,
/// multi-line SwiftUI `TextField` is backed by a `UITextView`, and there are iOS builds where it keeps
/// drawing the old string after the binding goes empty — the sent text stays visible in the box even
/// though the model is already empty, and the next keystroke makes it reappear in full.
///
/// Re-asserting focus makes the field read the binding again. It is deliberately narrow: only while
/// keeping the keyboard, only when the field was focused, and only on the empty transition — so it
/// can never fire while the user is typing, and it never competes with the dismiss preference, which
/// drops focus anyway.
public enum ComposerFocusRule {
    public static func shouldReassertFocus(previousDraft: String,
                                           currentDraft: String,
                                           isFocused: Bool,
                                           dismissKeyboardOnSend: Bool) -> Bool {
        guard isFocused, !dismissKeyboardOnSend else { return false }
        return !previousDraft.isEmpty && currentDraft.isEmpty
    }
}
