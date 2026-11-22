import Foundation
import Combine
import HermesKit
import HermesAppKit

#if os(iOS) && canImport(ActivityKit)
import ActivityKit

/// Keeps the Live Activity honest: one card per turn, from `isStreaming == true` to `isStreaming ==
/// false`.
///
/// It is an observer, not a participant. `AppModel.isStreaming` is already the app's single answer to
/// "is a turn running" — the same property the transcript spinner and the bot list's pose read — so
/// the card is driven from it rather than from a second set of hooks inside the model. That is why
/// this file needs no edit to `AppModel.swift`: `@Published` is a publisher, and a coordinator the
/// shell owns can subscribe to it. The model does not know the feature exists, which is also why the
/// Mac, a phone with Live Activities switched off, and a build against an SDK without ActivityKit all
/// keep compiling and running.
///
/// Three behaviours are deliberate and easy to get wrong:
///
/// * **One activity.** A second turn that begins while a card is showing *updates* that card
///   instead of requesting another. `Activity.request` is happy to stack two islands, and the one
///   nobody ended is the leak.
/// * **Orphans are swept.** Activities outlive the process: quit mid-turn (or crash) and the card
///   is still on the lock screen at the next launch, describing a turn that no longer exists. So
///   `attach` clears whatever is left of this attribute type before adopting the new run, and
///   `endAll` is public for a shell that gets a termination callback.
/// * **Silence is explained once.** Every path that cannot show a card records *why* in the client
///   log, once per reason — a phone with the feature turned off must not write 400 identical lines
///   into the log the owner opens to diagnose something else.
@MainActor
final class LiveActivityCoordinator: ObservableObject {

    /// Mirrors whether a card is on screen, for a settings row or a debug overlay. Nothing depends
    /// on it; the card's own lifecycle is the system's.
    @Published private(set) var isShowing = false

    /// How long a card may go without an update before the system greys it out. A turn that takes
    /// longer than this is not broken — the next `update` refreshes it — but a turn whose app died
    /// should stop claiming to be working.
    static let staleAfter: TimeInterval = 30 * 60

    /// How long the "replied" card stays after the turn ends. `end(dismissalPolicy:)` is the only
    /// way to flash a finished state: an activity removed immediately never shows it.
    static let doneLinger: TimeInterval = 6

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

    /// Reasons already written to the log, so a per-turn path cannot flood a 400-line ring.
    private var logged: Set<String> = []

    private var activity: Activity<HermeyTurnAttributes>?

    init() {}

    // MARK: Lifecycle

    /// Adopt a model's turn state. Idempotent for the same model, and safe to call from `.task` on
    /// the root view: attaching twice must not subscribe twice or start a second card.
    func attach(to model: AppModel) {
        guard self.model !== model else { return }
        detach()
        self.model = model

        // Before subscribing: a card left by a previous launch is cleaned up here, because the
        // subscription's first value is the *current* run and would otherwise be applied on top of
        // a stale card.
        endAll()

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
    }

    /// Stop observing and take the card down. Called by `attach` when a different model arrives.
    func detach() {
        cancellables.removeAll()
        model = nil
        endAll()
    }

    /// End every card of this type, ours or an orphan's.
    ///
    /// This is the `endAll` semantics the feature needs at two moments: at attach (a previous
    /// process may have died mid-turn) and from a shell that is about to terminate, where the card
    /// would otherwise sit on the lock screen for hours after the app is gone. `.immediate` because
    /// both callers are saying "this turn is not running any more" — there is nothing left to show.
    func endAll() {
        startedAt = nil
        replyTail = ""
        isShowing = false
        activity = nil
        let leftovers = Activity<HermeyTurnAttributes>.activities
        guard !leftovers.isEmpty else { return }
        Task {
            for leftover in leftovers {
                await leftover.end(nil, dismissalPolicy: .immediate)
            }
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
        let name = model?.selectedBot?.displayName ?? "Hermey"

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

        if let activity {
            // Same card, new turn: re-point the state rather than requesting a second activity.
            // `startedAt` resets so the elapsed timer counts this message, not the last one, and
            // the previous turn's reply is dropped rather than shown against this one.
            startedAt = now
            replyTail = ""
            let state = HermeyTurnAttributes.ContentState(phase: .working, startedAt: now)
            Task {
                await activity.update(ActivityContent(state: state,
                                                     staleDate: now.addingTimeInterval(Self.staleAfter)))
            }
            return
        }

        replyTail = ""
        do {
            let attributes = HermeyTurnAttributes(botName: name)
            let state = HermeyTurnAttributes.ContentState(phase: .working, startedAt: now)
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state,
                                         staleDate: now.addingTimeInterval(Self.staleAfter)),
                pushType: nil
            )
            startedAt = now
            isShowing = true
        } catch {
            // The usual causes are a per-app limit on simultaneous activities and an app that was
            // launched into the background; neither is worth a crash or a banner. The transcript
            // still has the turn.
            note("no card: the system refused the request (\(error.localizedDescription))")
        }
    }

    /// The reply landed — or the run was cancelled. Either way the card is over.
    private func finish() {
        guard let activity else { return }
        self.activity = nil
        isShowing = false

        let state = HermeyTurnAttributes.ContentState(
            phase: .done,
            startedAt: startedAt ?? Date(),
            finishedAt: Date(),
            replySnippet: replySnippet()
        )
        startedAt = nil
        replyTail = ""
        // Cleared before the end is awaited, so a turn that starts immediately after this one is not
        // blocked on the dismissal. The overlap is a few seconds at most and the old card has
        // already been told to go.
        Task {
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(Self.doneLinger))
            )
        }
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

    func endAll() {}

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
