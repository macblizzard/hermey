import Foundation

/// One bot, as the wire names it: the gateway's `profile` string.
///
/// Aliased rather than wrapped because that is what every layer already passes around — `Bot.id`,
/// `endlessSession(for:)`, `botFaces` — and a wrapper would only be unwrapped again at each call.
public typealias BotID = String

/// What each bot is doing, reduced from the events the client already receives.
///
/// The reference derives a bot's face from the *run*, not from a provider's free-text status
/// (`logo-avatar-activity.ts`), and this is that derivation with the run held as per-bot state. It
/// is deliberately not a view: nothing here imports SwiftUI, nothing here reads the clock, and every
/// method is a pure function of the state it is handed, so a test can drive one bot through a turn
/// and assert the face at each step without a socket, a host or a screen.
///
/// The precedence itself lives in `BotAvatarActivity.from(status:toolNames:composing:thinking:background:)`
/// and is *not* repeated here: this type only keeps the inputs that call needs, and `activity(for:)`
/// hands them over. That matters — a second copy of the ordering is how the roster and the reference
/// drift apart.
///
/// What it tracks, per bot:
///
/// | input | source event | what it decides |
/// | --- | --- | --- |
/// | `status` | turn lifecycle (`setStreaming`, `setStatus`) | idle / error / waiting / in flight |
/// | `openCalls` | `toolStart` … `toolComplete` | reading, writing, computer, working |
/// | `composing` | `messageDelta`, `interimMessage` | writing, when no tool is out |
/// | `thinking` | `thinkingDelta` | thinking, when nothing else is |
/// | `background` | `setBackground` | idle, over everything |
///
/// A tool leaves `openCalls` when it completes, which is what makes a finished tool fall back to
/// thinking (the model went back to deliberating) or working (it did not) instead of leaving the
/// face stuck on the pose of the tool it already finished.
public struct BotActivityTracker: Sendable {

    /// Everything one bot's next face is derived from. Exposed for tests; callers go through
    /// `activity(for:)`.
    public struct State: Sendable, Equatable {
        /// The run's lifecycle: `running`, `completed`, `failed`, `waiting_input`, or `nil`.
        public var status: String?
        /// Helper work that must not show up in the chat as activity.
        public var background: Bool
        /// Paused on the user (an approval or a clarify). Outranks everything but a failure.
        public var waitingOnUser: Bool
        /// Tools with a `toolStart` and no `toolComplete` yet, in the order they started.
        public var openCalls: [OpenCall]
        /// The model is writing a message.
        public var composing: Bool
        /// The model is reasoning.
        public var thinking: Bool

        public init(status: String? = nil,
                    background: Bool = false,
                    waitingOnUser: Bool = false,
                    openCalls: [OpenCall] = [],
                    composing: Bool = false,
                    thinking: Bool = false) {
            self.status = status
            self.background = background
            self.waitingOnUser = waitingOnUser
            self.openCalls = openCalls
            self.composing = composing
            self.thinking = thinking
        }
    }

    /// One tool call in flight: the id `toolComplete` matches on, and the wire name the face reads.
    public struct OpenCall: Sendable, Equatable, Hashable {
        public var callID: String
        public var name: String

        public init(callID: String, name: String) {
            self.callID = callID
            self.name = name
        }
    }

    private var states: [BotID: State] = [:]

    public init() {}

    // MARK: - Reading

    /// The face this bot should wear. An unknown bot is `idle`: nothing has happened yet, which is
    /// exactly what a bot you have never opened looks like.
    public func activity(for botID: BotID) -> BotAvatarActivity {
        let state = state(for: botID)
        return BotAvatarActivity.from(status: status(of: state),
                                      toolNames: state.openCalls.map(\.name),
                                      composing: state.composing,
                                      thinking: state.thinking,
                                      background: state.background)
    }

    /// The inputs behind that face. For tests and for a caller that wants to log *why* a bot looks
    /// busy; a view must use `activity(for:)`.
    public func state(for botID: BotID) -> State {
        states[botID] ?? State()
    }

    /// True while this bot has anything worth drawing — a cheap "should the list redraw" test.
    public func isActive(_ botID: BotID) -> Bool {
        activity(for: botID) != .idle
    }

    // MARK: - Writing

    /// Set the run's lifecycle directly. `failed` is the one status no event carries, so a caller
    /// that learns a turn failed (an RPC error attributed to the run) says so here.
    public mutating func setStatus(_ status: String?, for botID: BotID) {
        var state = states[botID] ?? State()
        state.status = status
        states[botID] = state
    }

    /// The client's own `isStreaming`, which is the run lifecycle it actually has.
    ///
    /// A turn that stops streaming is `completed`, and a turn that starts is `running` — unless it
    /// is paused on the user, which outranks both (a request answered does not make the run working
    /// again, and clearing that flag is `setWaitingOnUser(false)`'s job).
    public mutating func setStreaming(_ streaming: Bool, for botID: BotID) {
        var state = states[botID] ?? State()
        if streaming {
            if !BotAvatarActivity.isWorking(status: state.status) { state.status = "running" }
        } else if BotAvatarActivity.isWorking(status: state.status) {
            state.status = "completed"
            state.openCalls = []
            state.composing = false
            state.thinking = false
        }
        states[botID] = state
    }

    /// A run paused on the user: an approval, a clarify, a takeover.
    public mutating func setWaitingOnUser(_ waiting: Bool, for botID: BotID) {
        var state = states[botID] ?? State()
        state.waitingOnUser = waiting
        if waiting, !BotAvatarActivity.isWorking(status: state.status), state.status != "failed" {
            // A question cannot be asked by a run that is not happening; a host that reports the
            // request without a status still has a run in flight behind it.
            state.status = "running"
        }
        states[botID] = state
    }

    /// Helper work — a background run must never leak into the chat as a busy face.
    public mutating func setBackground(_ background: Bool, for botID: BotID) {
        var state = states[botID] ?? State()
        state.background = background
        states[botID] = state
    }

    /// The model started telling the user what it is doing (`message.delta`, `message.interim`).
    public mutating func setComposing(_ composing: Bool, for botID: BotID) {
        var state = states[botID] ?? State()
        state.composing = composing
        if composing {
            state.thinking = false
            start(botID: botID, state: &state)
        }
        states[botID] = state
    }

    /// A tool call began. While one is out the bot is no longer typing, but it may still be
    /// thinking: `thinking` is left alone so the face can fall back to it when the tool returns.
    public mutating func toolStarted(botID: BotID, name: String, callID: String) {
        var state = states[botID] ?? State()
        state.composing = false
        if !callID.isEmpty, let index = state.openCalls.firstIndex(where: { $0.callID == callID }) {
            // A replayed `tool.start` for a call already running: keep the first entry, refresh the
            // name (the host may have resolved one it did not have at the first event).
            if !name.isEmpty { state.openCalls[index].name = name }
        } else {
            state.openCalls.append(OpenCall(callID: callID, name: name))
        }
        start(botID: botID, state: &state)
        states[botID] = state
    }

    /// A tool reported progress. It carries no state change of its own — the call is still out —
    /// but it is proof the run is alive, so an unknown bot is marked running.
    public mutating func toolProgressed(botID: BotID, callID: String) {
        _ = callID   // the call is still the one that is out; progress carries no new state
        var state = states[botID] ?? State()
        start(botID: botID, state: &state)
        states[botID] = state
    }

    /// A tool finished. It leaves the in-flight set, so the face falls back to thinking or working
    /// rather than staying on the tool that is already done.
    ///
    /// `ok == false` is deliberately *not* `error`: the reference's error is a failed **run**, and a
    /// tool that failed is a tool the model is about to work around. The face turns back to
    /// thinking, which is the truth.
    public mutating func toolCompleted(botID: BotID, name: String?, callID: String, ok: Bool) {
        var state = states[botID] ?? State()
        if let index = state.openCalls.firstIndex(where: { $0.callID == callID }) {
            state.openCalls.remove(at: index)
        } else if let name, !name.isEmpty,
                  let index = state.openCalls.lastIndex(where: { $0.name == name }) {
            // A completion whose start this client never saw (a replay, or a tool that began before
            // the socket reattached) still closes a call of the same name.
            state.openCalls.remove(at: index)
        }
        start(botID: botID, state: &state)
        states[botID] = state
    }

    /// Reasoning arrived (`thinking.delta`). The decoder drops the empty heartbeat, so reaching here
    /// at all means the model deliberated.
    public mutating func thinking(botID: BotID) {
        var state = states[botID] ?? State()
        state.thinking = true
        start(botID: botID, state: &state)
        states[botID] = state
    }

    /// The turn settled (`message.complete`): no tools, no composing, no reasoning, no requests.
    public mutating func settled(botID: BotID) {
        var state = states[botID] ?? State()
        state.status = "completed"
        state.openCalls = []
        state.composing = false
        state.thinking = false
        state.waitingOnUser = false
        states[botID] = state
    }

    /// Forget one bot (deleted, or its conversation was reset).
    public mutating func reset(_ botID: BotID) {
        states.removeValue(forKey: botID)
    }

    /// Forget everything — a host change, or a disconnect that makes every face's state a guess.
    public mutating func resetAll() {
        states.removeAll()
    }

    // MARK: - Events

    /// Reduce one gateway event, for this bot.
    ///
    /// The four event families the face is derived from, in one place, so the two shells do not each
    /// keep their own `switch`. A caller with no bot for the event (a session it has never mapped)
    /// passes `nil` and nothing changes, which is the honest answer: an event attributed to the
    /// wrong bot is a wrong face.
    public mutating func apply(_ event: ClientEvent, bot botID: BotID?) {
        guard let botID else { return }
        switch event {
        case .toolStart(_, let name, let callID, _):
            toolStarted(botID: botID, name: name, callID: callID)
        case .toolProgress(_, let callID, _):
            toolProgressed(botID: botID, callID: callID)
        case .toolComplete(_, let name, let callID, _, let ok, _):
            toolCompleted(botID: botID, name: name, callID: callID, ok: ok)
        case .thinkingDelta(_, let text):
            // The empty heartbeat never reaches the app (the decoder drops it), but a caller that
            // synthesises one must not make the face think.
            if !text.isEmpty { thinking(botID: botID) }
        case .messageDelta, .interimMessage:
            setComposing(true, for: botID)
        case .messageComplete:
            settled(botID: botID)
        case .request:
            setWaitingOnUser(true, for: botID)
        case .requestCancelled:
            // Only the *last* request matters: a cancelled one does not mean the rest are answered,
            // so the caller clears the flag when its own request list empties.
            break
        case .ready, .state, .contextUsage, .sessionUpdated, .reactionUpdated, .error, .unknown:
            // A transport state is not a bot's state; `error` is the gateway's, not the run's, and
            // a reaction is somebody's emoji rather than work in flight.
            break
        }
    }

    // MARK: - Plumb

    /// The status `BotAvatarActivity.from` should see: a failure outranks a request, which outranks
    /// the lifecycle, exactly as the reference orders them.
    private func status(of state: State) -> String? {
        if state.status == "failed" { return "failed" }
        if state.waitingOnUser { return "waiting_input" }
        return state.status
    }

    /// A bot receiving any event is a bot with a run in flight, even if this client never saw the
    /// turn begin (a resumed session, a replay after a reconnect).
    private func start(botID: BotID, state: inout State) {
        if !BotAvatarActivity.isWorking(status: state.status), state.status != "failed" {
            state.status = "running"
        }
    }
}
