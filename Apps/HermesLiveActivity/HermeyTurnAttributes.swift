import Foundation

#if os(iOS) && canImport(ActivityKit)
import ActivityKit

// The eight words a bot state prints live in `BotStateWord`, which is compiled into this target (see
// `project.yml`) as well as into `HermesKit`. The extension must not **link** `HermesKit` — that is
// the whole networking stack — so this is a conditional import: the extension gets the type from
// this module, and the app, which compiles this same file, gets it from the package it already
// links.
#if canImport(HermesKit)
import HermesKit
#endif

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
/// three states need: the turn starts as `.working`, becomes `.needsYou` while the host is blocked
/// on an approval or a question, and is updated to `.done` when the reply lands. The bot's name sits
/// in the *attributes*, not the state: a turn belongs to one bot from start to finish, and switching
/// bots ends the turn (the shell cancels the run) rather than re-pointing it.
///
/// **Every word the card prints travels in this type.** The extension cannot read the app's model —
/// it is a second process with no bot list, no transcript and no stream — so a card whose text is a
/// literal, or is captured once when the activity is requested, can only ever say the same sentence
/// for every turn, and says nothing at all once that one captured string is empty. `step` is the
/// line the coordinator fills from the model as the turn moves (thinking, a tool, streaming), and
/// `ContentState` guarantees it is never blank: the neutral word for the phase is the floor.
public struct HermeyTurnAttributes: ActivityAttributes {
    /// Everything the card says that is allowed to change mid-turn.
    public struct ContentState: Codable, Hashable, Sendable {
        /// The three states the owner asked to see: working, blocked on him, then done. No queue and
        /// no error state — an error is a finished turn, and the transcript is where its reason
        /// lives.
        ///
        /// `needsYou` is not "the reply ends in a question mark". It is a run the app knows is
        /// paused on the owner — an approval or a question sitting in `AppModel.pendingRequests`,
        /// which is the same array the approval sheet is drawn from — so the card can only say it
        /// when the host is actually waiting for an answer.
        public enum Phase: String, Codable, Hashable, Sendable {
            case working
            case needsYou
            case done
        }

        /// How much of the reply a card may show, in characters.
        ///
        /// The lock screen gives a card two lines and the island gives it less; a message pasted
        /// whole into a snapshot is both unreadable and wasteful, because the whole state is copied
        /// into the system's activity store on every update. One hundred and twenty characters is
        /// roughly the two lines the card draws.
        public static let snippetLimit = 120

        /// How long the "what it is doing" line may be, in characters.
        ///
        /// It is drawn on *one* line under the bot's name, at caption size, so it is a phrase and
        /// not a sentence: "Running read_file", "Thinking it through", "Streaming the reply". A tool
        /// name or a bot's own wording can be longer than the line, so the cap lives here with the
        /// field rather than in each of the two views that draw it.
        public static let stepLimit = 48

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

        /// The first line or two of what the bot actually said.
        ///
        /// Empty while the turn runs, and empty when the coordinator had no reply text to hand
        /// over — an empty string is the honest value, and the views draw nothing for it rather
        /// than inventing a sentence. Assigning through `init` is what enforces the cap and the
        /// single line, so a long or multi-paragraph reply cannot reach the card unflattened.
        public var replySnippet: String

        /// What the bot is doing, in one short line: the state's word, "Running read_file", or
        /// "Streaming the reply".
        ///
        /// **Never empty.** This is the field the blank capsule was missing: the card exists from
        /// the moment `Activity.request` returns, and until now the only text it had was a literal
        /// in the view plus a name captured once at request time — so a card with no reply yet had
        /// nothing to say about the turn it was showing. The initialiser and the decoder both end
        /// at `neutral(_:)`, which is why no caller and no older activity can put a blank line on
        /// the lock screen. The coordinator writes the specific words; this type guarantees a floor.
        ///
        /// It sits *under* the phase word, not instead of it: the island and the card print
        /// `word(phase)` and then this line, which is why a card can say "Waiting for you · Running
        /// read_file" without the coordinator having to compose a sentence.
        public var step: String

        /// What the bot is *doing*, in the eight words every surface prints.
        ///
        /// `phase` is a transport fact — a turn runs, waits on him, or is over — and three values
        /// cannot say what a face should wear: a bot reading a file, driving a computer and thinking
        /// are all `working` here. This is the raw `BotStateWord` value (`thinking`, `reading`,
        /// `computer`, `blocked`, …), handed over by the coordinator from
        /// `AppModel.activity(forBot:)` — the same answer the roster badge and the pet draw — and the
        /// card draws the bot's own avatar wearing it, so a thinking bot looks like it is thinking on
        /// the Lock Screen instead of looking idle.
        ///
        /// A `String`, not an enum, for the reason every field on this type is tolerant: a card
        /// written by a later build may carry a word this build has never heard of, and that must
        /// draw a face (the phase's) rather than throw the card away. `state(from:phase:)` is the one
        /// normaliser, and `BotStateWord` is the vocabulary it validates against.
        public var botState: String

        public init(phase: Phase,
                    startedAt: Date,
                    finishedAt: Date? = nil,
                    replySnippet: String = "",
                    step: String = "",
                    botState: String = "") {
            self.phase = phase
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.replySnippet = Self.clipped(replySnippet)
            self.step = Self.stepLine(step, phase: phase)
            self.botState = Self.state(from: botState, phase: phase)
        }

        /// The step, flattened to one line and capped — or the neutral word for the phase.
        ///
        /// Public because the coordinator normalises the same way before it decides whether an
        /// update is worth sending: comparing two raw strings would let a line that clips to the
        /// same text count as a change, and push an identical snapshot at the system.
        public static func stepLine(_ text: String, phase: Phase) -> String {
            let flat = Self.clipped(text)
            guard !flat.isEmpty else { return Self.neutral(phase) }
            guard flat.count > stepLimit else { return flat }
            return String(flat.prefix(stepLimit))
        }

        /// The word for a phase, from `BotStateWord` — the one table of words the whole app uses.
        ///
        /// The compact pill, the expanded island and the Lock Screen card all draw this, so the
        /// three surfaces cannot drift into three vocabularies for the same turn. A phase is a
        /// transport fact (a turn runs, waits, or is over); the *words* are the bot vocabulary's, so
        /// `needsYou` reads "Waiting for you" and `done` reads "Done" exactly as the roster and the
        /// pet say them.
        ///
        /// Sentence case, one or two short words: it has to be legible in the compact pill, which
        /// is roughly a clock's width and is the whole point of the feature.
        public static func word(_ phase: Phase) -> String {
            switch phase {
            case .working: return BotStateWord.working.label
            case .needsYou: return BotStateWord.waiting.label
            case .done: return BotStateWord.done.label
            }
        }

        /// What a card says under the word when the app had nothing better: the same word, never
        /// blank.
        ///
        /// "Working" rather than "Working on your message" because this is the floor, not the
        /// writing: the coordinator supplies the real line, and a neutral word that is *true* beats
        /// a sentence that claims the turn is his when it may be a background sweep. Delegating to
        /// `word(_:)` is what keeps the floor and the status word from ever disagreeing — an old
        /// card whose step is missing says the phase's own word, `BotStateWord.done.label`.
        public static func neutral(_ phase: Phase) -> String {
            word(phase)
        }

        /// The eight-word state this card should draw, from a raw value that may be absent or newer
        /// than this build.
        ///
        /// One normaliser for both ends of the type: the coordinator's initialiser and the decoder of
        /// a card written by another build. An unknown word falls back to the *phase's* state —
        /// `working` for a running turn, `waiting` for one stopped on him, `done` for a finished one —
        /// so the face is always one of the eight and an old card still draws something true.
        public static func state(from raw: String?, phase: Phase) -> String {
            if let raw, BotStateWord(rawValue: raw) != nil { return raw }
            switch phase {
            case .working: return BotStateWord.working.rawValue
            case .needsYou: return BotStateWord.waiting.rawValue
            case .done: return BotStateWord.done.rawValue
            }
        }

        /// A phase from the raw value on the wire, tolerantly.
        ///
        /// A card can outlive the build that requested it, so the decoder must never throw on this
        /// field: a value this build does not know (a state a later build added, or an older
        /// activity written before `needsYou` existed) resolves to `.working`, and a missing key
        /// does too. Dropping the whole activity, or drawing a blank phase, are both worse than
        /// showing the one word that is true of any unfinished turn.
        public static func phase(from raw: String?) -> Phase {
            guard let raw, let phase = Phase(rawValue: raw) else { return .working }
            return phase
        }

        /// One line, at most `snippetLimit` characters.
        ///
        /// Newlines are the reason this exists: a reply is markdown with paragraphs, lists and
        /// fenced code in it, and a card that keeps the newlines draws one blank line and a
        /// paragraph break instead of words. Splitting on whitespace and re-joining with one space
        /// also folds the indentation a code block carries, which is what a two-line card needs.
        public static func clipped(_ text: String) -> String {
            let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard flat.count > snippetLimit else { return flat }
            return String(flat.prefix(snippetLimit))
        }

        // Written out because the decoder below is hand-written: with one requirement implemented
        // by hand it is clearer to name the keys than to lean on which half the compiler still
        // synthesises.
        private enum CodingKeys: String, CodingKey {
            case phase, startedAt, finishedAt, replySnippet, step, botState
        }

        // Decoded by hand for one reason: an activity requested by the previous build has no
        // `replySnippet` key (and 0.1.638's has no `step`), and the synthesised decoder would throw
        // and drop a card the owner is still looking at. A missing key is an empty string, not a
        // failure — and `step` still ends at the neutral word, so an old card in the middle of a
        // turn cannot draw a blank line either. The same tolerance covers `phase`: an unknown raw
        // value is `.working` rather than a thrown decoder, because the one field that picks the
        // word must never be the reason a card disappears.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawPhase = try container.decodeIfPresent(String.self, forKey: .phase)
            let phase = Self.phase(from: rawPhase)
            self.phase = phase
            self.startedAt = try container.decode(Date.self, forKey: .startedAt)
            self.finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
            self.replySnippet = Self.clipped(try container.decodeIfPresent(String.self, forKey: .replySnippet) ?? "")
            self.step = Self.stepLine(try container.decodeIfPresent(String.self, forKey: .step) ?? "",
                                      phase: phase)
            // …and an old card has no `botState` either: the phase's own state is the floor, so the
            // face is the bot's (a drawn avatar in `working`/`waiting`/`done`) rather than nothing.
            self.botState = Self.state(from: try container.decodeIfPresent(String.self, forKey: .botState),
                                       phase: phase)
        }
    }

    /// What the card calls a bot that has no name of its own.
    ///
    /// The app never resolves an id here — it hands over `Bot.displayName` — but a card with a
    /// blank name line is indistinguishable from a card with no content, which is the report this
    /// type exists to close. The floor is a word, not an empty string.
    public static let fallbackName = "Hermey"

    /// What the card calls the bot: `Bot.displayName`, resolved by the app at request time.
    /// Already a display string — the extension never resolves an id, because it has no bot list.
    public var botName: String

    /// The bot's own face, carried into the extension as three primitives.
    ///
    /// The card draws the avatar every other surface draws — the same renderer, the same motion —
    /// and a widget is a second process with no store, no bot list and (deliberately) no app group,
    /// so the face has to arrive in the activity itself. Three strings rather than a
    /// `BotAvatarDocument` on purpose: that type lives in `HermeyUI`, the extension compiles the
    /// *drawing* in rather than linking the package, and this file is the one file both processes
    /// compile — a shared model type here would make one of them import the other's module.
    ///
    /// Static, because a turn belongs to one bot from start to finish: the face cannot change
    /// mid-turn, so it is written once at `request` and never re-sent on an update.
    public var face: Face?

    /// Optional so an activity requested by the previous build still decodes: the synthesised
    /// decoder reads a missing optional as nil, and a bot with no drawn face keeps exactly the card
    /// it had (the phase's symbol). See `HermeyTurnAvatar`.
    public struct Face: Codable, Hashable, Sendable {
        /// The definition's own JSON, exactly as the host stores it.
        public var definition: String?
        /// `#RRGGBB`, or nil for the house colour.
        public var color: String?
        /// One of `BotAvatarMaterial`'s names, or nil for `solid`.
        public var material: String?

        public init(definition: String? = nil, color: String? = nil, material: String? = nil) {
            self.definition = definition
            self.color = color
            self.material = material
        }

        /// Whether there is a definition to draw at all. False for a bot that never chose an avatar,
        /// which is the branch that draws the SF Symbol instead.
        public var isDrawn: Bool {
            guard let definition else { return false }
            return !definition.isEmpty
        }
    }

    public init(botName: String, face: Face? = nil) {
        self.botName = Self.displayName(botName)
        self.face = face
    }

    /// One line, never empty. Public for the same reason `stepLine` is: the coordinator asks the
    /// same question of the name before it decides whether the attributes are worth re-stamping.
    public static func displayName(_ name: String) -> String {
        let flat = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.isEmpty ? fallbackName : flat
    }
}
#endif
