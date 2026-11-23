import Foundation
import Combine
import HermesKit
import HermesAppKit

#if os(iOS) && canImport(ActivityKit)
import ActivityKit

/// Keeps the Live Activity honest: one card per turn, from `isStreaming == true` to `isStreaming ==
/// false`, and it stays on screen until the owner takes it away.
///
/// It is an observer, not a participant. `AppModel.isStreaming` is already the app's single answer to
/// "is a turn running" — the same property the transcript spinner and the bot list's pose read — so
/// the card is driven from it rather than from a second set of hooks inside the model. That is why
/// this file needs no edit to `AppModel.swift`: `@Published` is a publisher, and a coordinator the
/// shell owns can subscribe to it. The model does not know the feature exists, which is also why the
/// Mac, a phone with Live Activities switched off, and a build against an SDK without ActivityKit all
/// keep compiling and running.
///
/// **Four behaviours are deliberate and easy to get wrong:**
///
/// * **One activity, reused.** A second turn *updates* the card that is already up — including a
///   card left showing `Done` by the previous turn, which is still on screen (and still updatable)
///   because nothing ended it. `Activity.request` is the last resort: only when the process holds no
///   handle and nothing of this type is on screen.
/// * **Nothing ends it but the owner.** The owner's rule is "it should stay unless I remove them",
///   and `Activity.end(_:dismissalPolicy:)` is the only call that can take a card away — `.immediate`
///   removes it outright, and even `.default` clears the Dynamic Island immediately and keeps only
///   the Lock Screen copy. So there is **no `end` call in this file at all**: a finished turn is an
///   `update` to `.done`, and the card lives until he swipes it away or the system's own ceiling
///   (eight hours) closes in. That is also why `staleAfter` is that ceiling and not thirty minutes:
///   a card that greyed out mid-turn would be the same complaint wearing a hat.
/// * **A leftover is told the truth, not yanked.** Activities outlive the process: quit mid-turn (or
///   crash) and the card is still on the lock screen at the next launch, describing a turn that no
///   longer exists. `attach` *updates* whatever is left of this type to `Done` before adopting the
///   new run — it never ends it, so nothing blinks off his Lock Screen during a launch.
/// * **Silence is explained once.** Every path that cannot show a card records *why* in the client
///   log, once per reason — a phone with the feature turned off must not write 400 identical lines
///   into the log the owner opens to diagnose something else.
@MainActor
final class LiveActivityCoordinator: ObservableObject {

    /// Mirrors whether a card is on screen, for a settings row or a debug overlay. It stays true
    /// after a turn ends, because the finished card is still there.
    @Published private(set) var isShowing = false

    /// How long a card may go without an update before the system greys it out.
    ///
    /// Effectively "never": eight hours is the ceiling the system itself enforces on a Live
    /// Activity, so a card cannot grey out before it is removed anyway. A shorter value would make a
    /// long turn look abandoned — the card greys, the sentence steps back to "Still waiting on" —
    /// which is exactly the behaviour the owner asked to stop.
    static let staleAfter: TimeInterval = 8 * 60 * 60

    /// Weak: `AppEnvironment` owns the model and the shell owns this coordinator, so a strong link
    /// back would only make the teardown order matter.
    private weak var model: AppModel?

    private var cancellables: Set<AnyCancellable> = []

    /// When the current turn started, kept so the `.done` update can still say how long it ran.
    private var startedAt: Date?

    /// The tail of what the bot is saying, kept while it streams.
    ///
    /// `finish` runs when `isStreaming` flips back, and by then the model has already emptied
    /// `streamingText` — the live bubble is what clears it. So the words are read as they arrive and
    /// the tail is held here; the card's own cap is 120 characters, and this keeps the few hundred
    /// before it, so the snippet is cut from real text and not from a sentence that starts mid-word
    /// because the stream was joined late.
    private var replyTail: String = ""

    /// How much of the stream is kept for the snippet. Generous next to the card's 120 characters,
    /// small enough that a long answer is not held a second time in an observer.
    private static let replyTailLimit = 400

    /// The step line the card is currently showing, already normalised the way the state normalises
    /// it. The model publishes tools and tokens as they arrive; this is what stops a token arriving
    /// every 40 ms from becoming an activity update every 40 ms.
    private var lastStep: String = ""

    /// Reasons already written to the log, so a per-turn path cannot flood a 400-line ring.
    private var logged: Set<String> = []

    /// The card this process is driving. Kept across a finished turn on purpose: the `Done` card is
    /// still on screen and updatable, and the next turn re-points it instead of stacking a second.
    private var activity: Activity<HermeyTurnAttributes>?

    /// The sweep of anything left on screen by an earlier launch, while it is still in flight.
    private var retirement: Task<Void, Never>?

    init() {}

    // MARK: Lifecycle

    /// Adopt a model's turn state. Idempotent for the same model, and safe to call from `.task` on
    /// the root view: attaching twice must not subscribe twice or start a second card.
    func attach(to model: AppModel) {
        guard self.model !== model else { return }
        detach()
        self.model = model

        // Before subscribing: a card left by a previous launch is retired here, because the
        // subscription's first value is the *current* run and would otherwise be applied on top of
        // a stale card.
        retireLeftovers()

        model.$isStreaming
            .removeDuplicates()
            .sink { [weak self] streaming in
                guard let self else { return }
                if streaming {
                    self.begin()
                } else {
                    self.finish()
                }
            }
            .store(in: &cancellables)

        // Second, and after the turn subscription on purpose: the card's snippet is the reply, and
        // the reply only exists in the model while it streams. This is a passive copy — it starts
        // no work, and the sink is one string assignment per publish (the model already coalesces
        // tokens to a 40 ms beat).
        model.$streamingText
            .removeDuplicates()
            .sink { [weak self] text in
                guard let self else { return }
                let tail = String(text.suffix(Self.replyTailLimit))
                if !tail.isEmpty { self.replyTail = tail }
            }
            .store(in: &cancellables)

        // Third: what the bot is *doing*, not only that it is running. A card that says "working"
        // for the whole turn is a card with nothing to say about this one — and one whose input the
        // system never refreshes is how the lock screen came to show a tint and no words. The four
        // sources are mapped to a single line before they are compared, so the step is pushed when
        // it changes (a tool starts, the thinking stream opens, the reply starts streaming) and not
        // once per token.
        Publishers.CombineLatest4(model.$liveTools,
                                  model.$streamingText,
                                  model.$reasoningText,
                                  model.$botActivityTracker)
            .sink { [weak self] _, _, _, _ in
                guard let self else { return }
                self.progress()
            }
            .store(in: &cancellables)
    }

    /// Stop observing. The card is **not** taken down: it is still the owner's to dismiss.
    ///
    /// Called by `attach` when a different model arrives (a re-pair keeps the shell and swaps the
    /// model), where the card on screen describes a turn this process can no longer follow — so it
    /// is retired to `Done` rather than left claiming to work.
    func detach() {
        cancellables.removeAll()
        model = nil
        retireLeftovers()
    }

    /// Hand every card of this type on screen a true sentence, and forget our handle on it.
    ///
    /// This replaced the old `endAll()`, which ended each card with `.immediate`. That was the
    /// second half of "it disappears seconds after it appears": a launch, a re-pair or a termination
    /// callback could take a card the owner was still looking at. Nothing here ends anything —
    /// the leftovers are *updated* to a finished state, which is both honest (the turn behind them
    /// is gone) and quiet (the card behaves like any other finished one: it waits for him).
    func retireLeftovers() {
        startedAt = nil
        replyTail = ""
        lastStep = ""
        activity = nil
        let leftovers = Activity<HermeyTurnAttributes>.activities
        let now = Date()
        let state = HermeyTurnAttributes.ContentState(phase: .done,
                                                      startedAt: now,
                                                      finishedAt: now,
                                                      step: Self.doneWords)
        let content = ActivityContent(state: state, staleDate: nil)
        guard !leftovers.isEmpty else {
            retirement = nil
            isShowing = false
            return
        }
        // Held so a turn that begins in the same launch can wait for this write. Without it the
        // sweep could land *after* `begin`'s update and leave the new turn reading `Done`.
        retirement = Task {
            for leftover in leftovers {
                await leftover.update(content)
            }
        }
        isShowing = true
    }

    /// Hand a state to a card, once any sweep from this launch has landed.
    ///
    /// Every transition goes through here rather than calling `update` at the call site: the sweep
    /// at `attach` is asynchronous, and two updates racing on the same activity is how a card shows
    /// the wrong phase.
    private func push(_ content: ActivityContent<HermeyTurnAttributes.ContentState>,
                      to card: Activity<HermeyTurnAttributes>) {
        let pending = retirement
        Task {
            await pending?.value
            await card.update(content)
        }
    }

    // MARK: Turn transitions

    /// A turn just began (or a second one began on top of a showing card).
    ///
    /// A run that is already in flight when the coordinator attaches starts its timer now rather
    /// than at the moment the owner actually sent the message: `AppModel` publishes that a turn is
    /// running, not when it started, and a card counting from a second ago is better than a card
    /// counting from zero.
    private func begin() {
        let now = Date()
        let name = model?.selectedBot?.displayName ?? HermeyTurnAttributes.fallbackName
        // Read once, before the request: the card is on screen from the moment `request` returns,
        // and the first frame iOS draws is this state. A start with no step is a card with no words
        // until the next publish, which for a slow first token is the whole turn.
        let startStep = normalisedStep()

        // 16.2 rather than 16.1 on purpose: this coordinator uses the content-carrying
        // `request`/`update`, which arrived in 16.2 and is the form 16.1's API was deprecated in
        // favour of. The app's own floor is iOS 17, so on any device that can install Hermey this
        // is already true; the guard exists so the source is explicit about the API it needs and so
        // a build that ever lowers the floor degrades instead of crashing.
        guard #available(iOS 16.2, *) else {
            note("no card: Live Activities need iOS 16.2 or later")
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            note("no card: Live Activities are turned off for Hermey in Settings")
            return
        }

        let state = HermeyTurnAttributes.ContentState(phase: .working,
                                                      startedAt: now,
                                                      step: startStep)
        let content = ActivityContent(state: state,
                                      staleDate: now.addingTimeInterval(Self.staleAfter))

        startedAt = now
        replyTail = ""
        lastStep = startStep

        if let current = activity,
           current.activityState == .active || current.activityState == .stale {
            // Same card, new turn: re-point the state rather than requesting a second activity.
            // `startedAt` resets so the elapsed timer counts this message, not the last one, and
            // the previous turn's reply is dropped rather than shown against this one.
            push(content, to: current)
            isShowing = true
            return
        }
        // A card the owner swiped away is not a card to update: its handle is dropped and the
        // request below starts a fresh one.
        activity = nil

        // A card this process does not hold but the system still has on screen — the `Done` card of
        // the last turn, or one left by a launch that died. Updating it is the difference between
        // one island and two. The bot's name lives in the *attributes*, which an update cannot
        // change, so only a card that already belongs to this bot is adopted.
        if let lingering = Activity<HermeyTurnAttributes>.activities.first(where: { $0.attributes.botName == name }) {
            activity = lingering
            isShowing = true
            push(content, to: lingering)
            return
        }

        do {
            let attributes = HermeyTurnAttributes(botName: name)
            activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            isShowing = true
        } catch {
            // The usual causes are a per-app limit on simultaneous activities and an app that was
            // launched into the background; neither is worth a crash or a banner. The transcript
            // still has the turn.
            note("no card: the system refused the request (\(error.localizedDescription))")
        }
    }

    /// The reply landed — or the run was cancelled. Either way the turn is over; the card is not.
    ///
    /// The finished card says `Done` and then, when there is one, the reply's first line: the step
    /// field is the turn's last word, so the end state cannot fall back to a tint with no text even
    /// when the turn produced nothing the coordinator caught.
    ///
    /// **It is updated, not ended.** See the type's doc: `end` is what removes a card from the
    /// island, and the owner wants the island to keep saying `Done` until he takes it away. The
    /// handle is kept so the *next* turn re-points this same card back to `.working`.
    private func finish() {
        // `startedAt` is the "a turn was actually observed" flag: a second `false` from
        // `isStreaming`, or the first value at attach on a phone where nothing is running, must not
        // rewrite a finished card with a fresh zero elapsed.
        guard let activity, let startedAt else { return }

        let state = HermeyTurnAttributes.ContentState(
            phase: .done,
            startedAt: startedAt,
            finishedAt: Date(),
            replySnippet: replySnippet(),
            step: Self.doneWords
        )
        self.startedAt = nil
        replyTail = ""
        lastStep = ""
        // `staleDate: nil` — a finished card is not going to produce anything else, so there is
        // nothing for the system to grey out.
        let content = ActivityContent(state: state, staleDate: nil)
        push(content, to: activity)
    }

    /// The word a finished turn ends on. One word, because the reply's first line is the sentence
    /// underneath it — and because "Replied" claimed a reply that a cancelled turn never had.
    static let doneWords = "Done"

    // MARK: What the bot is doing

    /// The card's one-line status, in the app's own vocabulary.
    ///
    /// The words come from the same place the app's working row reads: `BotActivityTracker` through
    /// `activity(forBot:)`, plus the tool that is actually out. `WorkingStatus` draws kaomoji for
    /// the chat, which is right in a bubble and wrong on a lock screen, so this maps the same eight
    /// activities to plain phrases rather than inventing a second notion of what a bot is doing.
    ///
    /// A running tool wins over the pose: "Running read_file" is more useful than "Reading", and the
    /// tool's own name is what the transcript will show afterwards.
    private func stepLine() -> String {
        guard let model else { return "" }
        if let tool = model.liveTools.last(where: { $0.isRunning }) {
            let name = tool.name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return "Running \(name.isEmpty ? "a tool" : name)"
        }
        let activity = model.selectedBotID.map { model.activity(forBot: $0) } ?? .working
        switch activity {
        case .thinking: return "Thinking it through"
        case .reading: return "Reading"
        case .writing: return "Writing"
        case .computer: return "Using the computer"
        case .waiting: return "Waiting on you"
        case .error: return "Stopped with an error"
        case .idle, .working: break
        }
        if !model.streamingText.isEmpty { return "Streaming the reply" }
        return "Working on your message"
    }

    /// The step as the card will store it, so a line that clips to the same 48 characters is not
    /// counted as progress and does not become an update.
    private func normalisedStep() -> String {
        HermeyTurnAttributes.ContentState.stepLine(stepLine(), phase: .working)
    }

    /// Push the current step, if it changed.
    ///
    /// This is the path the card was missing: `begin` set the state once and nothing refreshed it,
    /// so the lock screen held the frame from the moment the activity was requested — the bot's
    /// name and a literal, and nothing about what the turn was actually doing. Skipping the update
    /// when the line is unchanged is what keeps a streaming reply from costing one activity write
    /// per token: `streamingText` publishes about every 40 ms and the step changes twice.
    private func progress() {
        guard let activity, let startedAt else { return }
        let step = normalisedStep()
        guard step != lastStep else { return }
        lastStep = step
        let now = Date()
        let state = HermeyTurnAttributes.ContentState(phase: .working,
                                                      startedAt: startedAt,
                                                      step: step)
        let content = ActivityContent(state: state,
                                      staleDate: now.addingTimeInterval(Self.staleAfter))
        push(content, to: activity)
    }

    // MARK: The snippet

    /// What the bot said, or nothing.
    ///
    /// Two sources, in order: the tail kept while the reply streamed, then the transcript's last
    /// assistant row — the fallback matters for a turn that was already running when the
    /// coordinator attached, and for one whose answer arrived entirely as sealed rows rather than
    /// as streamed tokens. Neither source is ever synthesised: if both are empty the card gets an
    /// empty string and draws no snippet, which is the truth ("a turn ended and there was no text").
    ///
    /// No trimming happens here. `ContentState` flattens and caps what it is given, so the rule for
    /// what a card may show lives in one place, next to the field.
    private func replySnippet() -> String {
        if !replyTail.isEmpty { return replyTail }
        guard let model else { return "" }
        return model.transcript.last(where: { $0.role == .assistant })?.text ?? ""
    }

    // MARK: Logging

    /// One line per distinct reason, in the log the app's Settings → View log already shows.
    ///
    /// `ClientLog.record` also mirrors to `os.Logger` (subsystem `dev.hermey.app`, category
    /// `live-activity`), so `log stream` explains a missing card without the owner opening the app.
    private func note(_ reason: String) {
        guard logged.insert(reason).inserted else { return }
        ClientLog.shared.record("Live Activity: \(reason)", level: .info, category: "live-activity")
    }
}

#else

/// The same type on every other platform, so nothing that mentions `LiveActivityCoordinator` has to
/// be wrapped in `#if` itself: the Mac and any build without ActivityKit in its SDK get a coordinator
/// that does nothing and says why once.
@MainActor
final class LiveActivityCoordinator: ObservableObject {
    private var logged = false

    init() {}

    func attach(to model: AppModel) {
        noteOnce()
    }

    func detach() {}

    func retireLeftovers() {}

    var isShowing: Bool { false }

    private func noteOnce() {
        guard !logged else { return }
        logged = true
        ClientLog.shared.record("Live Activity: not available on this platform",
                                level: .info,
                                category: "live-activity")
    }
}

#endif
