import Foundation

/// Whether the app is usable yet — the one question the launch screen asks.
///
/// The app opens onto a screen that is not yet the app: the socket is being dialled, the host has
/// not listed its bots, and the selected bot's sessions have not been read. That window has a
/// beginning and, usually, a quick end. This type is the whole of the decision about it: it holds
/// the three answers the app actually publishes, a hard deadline, and nothing else — no clock of
/// its own, no timers, no view state. Callers hand it the time, so the deadline can be tested
/// without waiting twelve seconds.
///
/// ```swift
/// var readiness = LaunchReadiness()
/// readiness.begin(at: now)
/// switch readiness.advance(signals, at: now) {
/// case .waiting: draw the launch screen
/// case .ready:   fade it out — the app behind it is already usable
/// case .failed:  stop covering the app; leave the person with the connect/pair UI
/// }
/// ```
///
/// ## The three answers, and why these three
///
/// - **paired**: an install with no host can never become usable by waiting, so it leaves through
///   `failed(.notPaired)` on the first evaluation. A splash over a pairing screen nobody can reach
///   is a wall, not a loading state.
/// - **connected**: `AppModel.connection.isLive`. The socket is the thing every other signal rides
///   on; until it is up, nothing behind the splash can be read.
/// - **roster answered** and **sessions answered**: the two reads both shells wait for. They are
///   *answered*, not *non-empty*: a host with zero bots is usable and must not sit on a splash
///   until the deadline, which is why `AppModel.rosterAnswered` exists rather than a `!bots.isEmpty`
///   guess.
///
/// ## The deadline
///
/// A host that never answers cannot trap anyone on a splash: once `deadline` seconds have passed the
/// phase is `.failed(.deadline)`, which is a hand-off, not a retry — the overlay goes away and the
/// app's own connect/pair UI is what the person gets, with its words and its buttons. Both terminal
/// phases are final: a splash that came back after the host finally answered, or after the person
/// pressed Connect, would be a second launch screen in the middle of the app.
public struct LaunchReadiness: Equatable, Sendable {

    /// What the app can say about itself at one instant.
    ///
    /// Five booleans, because that is what `AppModel` publishes; nothing here is derived, guessed or
    /// timed. `AppModel.launchSignals(isPaired:)` is the only producer in the app.
    public struct Signals: Equatable, Sendable {
        /// This install has a host to talk to at all.
        public var isPaired: Bool
        /// `AppModel.Connection.isLive` — the socket is up.
        public var isConnected: Bool
        /// `AppModel.Connection.failed` — connect or the first read gave up. Distinct from "slow":
        /// a failure has words in it, and the app's own banner is where those words belong.
        public var connectionFailed: Bool
        /// `profiles.list` has returned this launch, empty list and error included.
        public var rosterAnswered: Bool
        /// `session.list` has returned for the bot that was selected when it was asked.
        public var sessionsAnswered: Bool

        public init(isPaired: Bool,
                    isConnected: Bool,
                    connectionFailed: Bool,
                    rosterAnswered: Bool,
                    sessionsAnswered: Bool) {
            self.isPaired = isPaired
            self.isConnected = isConnected
            self.connectionFailed = connectionFailed
            self.rosterAnswered = rosterAnswered
            self.sessionsAnswered = sessionsAnswered
        }

        /// Everything answered, nothing failed: the app behind the splash is usable.
        public static let usable = Signals(isPaired: true,
                                           isConnected: true,
                                           connectionFailed: false,
                                           rosterAnswered: true,
                                           sessionsAnswered: true)

        /// Nothing asked yet: what the first frame of a paired launch looks like.
        public static let unanswered = Signals(isPaired: true,
                                              isConnected: false,
                                              connectionFailed: false,
                                              rosterAnswered: false,
                                              sessionsAnswered: false)
    }

    /// Why the launch screen stopped covering the app without the app being ready.
    ///
    /// Every case is a hand-off to UI that already exists, which is the point: the launch screen
    /// never owns a message, a retry or a button.
    public enum Failure: String, Equatable, Sendable {
        /// No host is paired. The pair screen is the app on this install.
        case notPaired
        /// The socket, or the first read over it, failed. `AppModel.Connection.failed` carries the
        /// reason and the connection banner already draws it.
        case connection
        /// Nothing answered within `LaunchReadiness.defaultDeadline`.
        case deadline

        /// Whether this failure is the person's to fix by connecting (the deadline and a dead
        /// socket), as opposed to by pairing.
        public var wantsConnectionUI: Bool { self != .notPaired }
    }

    /// Where launch is.
    public enum Phase: Equatable, Sendable {
        /// Still waiting: the launch screen is what should be on screen.
        case waiting
        /// Usable: the launch screen may go away.
        case ready
        /// Not usable, and waiting will not help: the app's own UI takes over.
        case failed(Failure)
    }

    /// Twelve seconds.
    ///
    /// Chosen against the reads this gate waits for, not picked for roundness: `profiles.list` and
    /// `session.list` each have their own transport timeout in `GatewayClientActor`, and a phone
    /// coming back from the background re-dials a sleeping host. A cold host that answers at all
    /// answers well inside this; one that does not is not going to, and twelve seconds is about as
    /// long as a splash is believable.
    public static let defaultDeadline: TimeInterval = 12

    /// The hard stop, in seconds. Zero or negative is treated as zero: expire on the first
    /// evaluation rather than on a later one.
    public let deadline: TimeInterval

    public private(set) var phase: Phase = .waiting

    /// When `begin(at:)` was first called, on the caller's clock.
    public private(set) var startedAt: TimeInterval?

    public init(deadline: TimeInterval = LaunchReadiness.defaultDeadline) {
        self.deadline = max(deadline, 0)
    }

    /// Nothing more will change: `ready` and `failed` are both final.
    public var isTerminal: Bool { phase != .waiting }

    /// The one thing a view reads to decide whether to cover the app.
    ///
    /// Deliberately a property of the *phase* and nothing else: a view that also consulted
    /// `bots.isEmpty` or a timer of its own would be a second copy of this decision.
    public var showsBootScreen: Bool { phase == .waiting }

    /// Whether the deadline is what ended the wait.
    public var didTimeOut: Bool { phase == .failed(.deadline) }

    /// Start the clock. Idempotent: a redraw is not a second launch.
    public mutating func begin(at now: TimeInterval) {
        guard startedAt == nil else { return }
        startedAt = now
    }

    /// Evaluate one instant and return the phase it lands on.
    ///
    /// The order of the checks is the contract, and each one exists because it is the earliest
    /// truthful answer:
    ///
    /// 1. a terminal phase is returned untouched;
    /// 2. `!isPaired` → `failed(.notPaired)` (immediate, on the first evaluation);
    /// 3. `connectionFailed` → `failed(.connection)`;
    /// 4. `elapsed >= deadline` → `failed(.deadline)`;
    /// 5. all five signals → `ready`;
    /// 6. otherwise `.waiting`.
    ///
    /// The deadline outranks readiness on purpose: a host that answers at the stroke of the deadline
    /// is late, and the person is already owed the app's own screen rather than a splash that has
    /// outstayed its welcome.
    @discardableResult
    public mutating func advance(_ signals: Signals, at now: TimeInterval) -> Phase {
        guard !isTerminal else { return phase }
        begin(at: now)

        if !signals.isPaired {
            phase = .failed(.notPaired)
            return phase
        }
        if signals.connectionFailed {
            phase = .failed(.connection)
            return phase
        }
        let elapsed = now - (startedAt ?? now)
        if elapsed >= deadline {
            phase = .failed(.deadline)
            return phase
        }
        if signals.isConnected, signals.rosterAnswered, signals.sessionsAnswered {
            phase = .ready
            return phase
        }
        return phase
    }
}
