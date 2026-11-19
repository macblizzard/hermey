import XCTest
@testable import HermeyUI

/// The composer's two behaviours around sending: putting the keyboard away, and making the field
/// agree with the model once the draft is cleared.
///
/// The rule is deliberately narrow, and these tests are mostly about what it must *not* do — a focus
/// flip that fires while someone is typing would interrupt them, and one that fires against the
/// dismiss preference would fight it.
final class ComposerFocusRuleTests: XCTestCase {

    func testReassertsWhenAFocusedFieldIsClearedWithTheKeyboardKept() {
        XCTAssertTrue(
            ComposerFocusRule.shouldReassertFocus(previousDraft: "hello",
                                                  currentDraft: "",
                                                  isFocused: true,
                                                  dismissKeyboardOnSend: false),
            "the sent-text-stays case: focused, keyboard kept, draft cleared"
        )
    }

    func testNeverFiresWhileSomeoneIsTyping() {
        XCTAssertFalse(
            ComposerFocusRule.shouldReassertFocus(previousDraft: "hel",
                                                  currentDraft: "hell",
                                                  isFocused: true,
                                                  dismissKeyboardOnSend: false)
        )
        XCTAssertFalse(
            ComposerFocusRule.shouldReassertFocus(previousDraft: "hello",
                                                  currentDraft: "hello!",
                                                  isFocused: true,
                                                  dismissKeyboardOnSend: false)
        )
    }

    func testNeverFiresWhenTheKeyboardIsBeingDismissed() {
        // With the dismiss preference on, focus is dropped on purpose; re-asserting it would put the
        // keyboard straight back up.
        XCTAssertFalse(
            ComposerFocusRule.shouldReassertFocus(previousDraft: "hello",
                                                  currentDraft: "",
                                                  isFocused: true,
                                                  dismissKeyboardOnSend: true)
        )
    }

    func testNeverFiresWhenTheFieldWasNotFocused() {
        XCTAssertFalse(
            ComposerFocusRule.shouldReassertFocus(previousDraft: "hello",
                                                  currentDraft: "",
                                                  isFocused: false,
                                                  dismissKeyboardOnSend: false)
        )
    }

    func testDoesNotFireOnAnAlreadyEmptyField() {
        XCTAssertFalse(
            ComposerFocusRule.shouldReassertFocus(previousDraft: "",
                                                  currentDraft: "",
                                                  isFocused: true,
                                                  dismissKeyboardOnSend: false),
            "clearing an empty draft is not a send"
        )
    }

    // MARK: - The preference

    func testThePreferenceIsNamespacedAndOnByDefault() {
        XCTAssertEqual(ComposerPreferences.dismissKeyboardOnSendKey, "hermey.composer.dismissKeyboardOnSend")
        XCTAssertTrue(ComposerPreferences.defaultDismissKeyboardOnSend,
                      "the composer's job ends when the message is sent; the keyboard should go")
    }
}
