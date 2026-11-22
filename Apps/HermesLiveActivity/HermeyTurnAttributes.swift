import Foundation

#if os(iOS) && canImport(ActivityKit)
import ActivityKit

/// One turn of the owner's message: a bot picks it up, works on it, and lands a reply.
///
/// This is the *only* file shared by the app and the extension, and it is deliberately the only
/// thing they share. A Live Activity is two processes — the app asks for one, the widget extension
/// draws it — so the attributes type has to exist in both. It is compiled into both targets from
/// this one file rather than copied: a second declaration would drift, and `Activity.request`
/// would hand the extension a type it has never heard of (which fails at runtime, silently, with
/// an activity that never appears).
///
/// Nothing here imports the app module. The extension must not link `HermesAppKit` (or `HermesKit`),
/// because a widget extension is loaded by the system into *its* process and pulling the app's
/// networking/state stack in with it is both a size problem and a launch-time problem. That is why
/// there is no `Bot` here, only the one string the card actually prints.
///
/// `ContentState` is the half that may change while the activity lives, which is exactly what the
/// two states need: the turn starts as `.working` and is updated to `.done` when the reply lands.
/// The bot's name sits in the *attributes*, not the state: a turn belongs to one bot from start to
/// finish, and switching bots ends the turn (the shell cancels the run) rather than re-pointing it.
public struct HermeyTurnAttributes: ActivityAttributes {
    /// Everything the card says that is allowed to change mid-turn.
    public struct ContentState: Codable, Hashable, Sendable {
        /// The two states the owner asked to see: working, then done. No queue, no error state —
        /// an error is a finished turn, and the transcript is where its reason lives.
        public enum Phase: String, Codable, Hashable, Sendable {
            case working
            case done
        }

        public var phase: Phase

        /// When the turn began, not how long it has run.
        ///
        /// A duration would be wrong the moment the system redraws the card — Live Activity views
        /// are snapshots, so a stored `TimeInterval` freezes at the value the app last sent. A
        /// `Date` plus `Text(_, style: .timer)` makes the system's own clock do the counting, which
        /// is the only way an elapsed time stays true without the app pushing an update per second.
        public var startedAt: Date

        /// When the reply landed. `nil` while `.working`, set on the single `.done` update so the
        /// finished card can say "just now" without a second round trip.
        public var finishedAt: Date?

        public init(phase: Phase, startedAt: Date, finishedAt: Date? = nil) {
            self.phase = phase
            self.startedAt = startedAt
            self.finishedAt = finishedAt
        }
    }

    /// What the card calls the bot: `Bot.displayName`, resolved by the app at request time.
    /// Already a display string — the extension never resolves an id, because it has no bot list.
    public var botName: String

    public init(botName: String) {
        self.botName = botName
    }
}
#endif
