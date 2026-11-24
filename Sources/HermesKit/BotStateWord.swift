import Foundation

/// The eight states a bot can be in, each reduced to the one word every surface prints.
///
/// This file is the single source of those words. `BotAvatarActivity.label` asks it, the bot list's
/// badge asks it, the desktop pet asks it, and the iOS Live Activity asks it — so a status line can
/// no longer say "Working" while the face says `writing`, or "Finished" while the list says idle.
///
/// **Why a second enum at all?** Because three of those surfaces are not in this module. A widget
/// extension is loaded into its own process and must not link `HermesKit` (see
/// `Apps/HermesLiveActivity/HermeyTurnAttributes.swift`), so it cannot call a function that lives
/// only in this target. This file is compiled *into* the extension as well as into `HermesKit`
/// (`project.yml`), which is what lets one function serve both processes. It deliberately imports
/// nothing but Foundation and holds no state: it is a table of words, not a vocabulary.
///
/// The case list is kept identical to `BotAvatarActivity`'s, in the same order, by
/// `Tests/test_bot_states.py`. If one grows a state and the other does not, that test fails before a
/// surface can print a word no face can wear.
public enum BotStateWord: String, CaseIterable, Hashable, Sendable {
    case idle
    case thinking
    case reading
    case working
    case computer
    case waiting
    case blocked
    case done

    /// The word for this state, and the only place these eight strings exist.
    ///
    /// Sentence case and short: it is drawn in a roster row, on a pet and in a Live Activity's
    /// compact slot, so "Using the computer" is the longest thing any of them has to fit.
    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .reading: return "Reading"
        case .working: return "Working"
        case .computer: return "Using the computer"
        case .waiting: return "Waiting for you"
        case .blocked: return "Blocked"
        case .done: return "Done"
        }
    }
}
