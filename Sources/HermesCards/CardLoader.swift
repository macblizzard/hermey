import Foundation
import HermesKit

/// The transcript's card lookups: one fetch per `(session, message, card id)`, cached, and never
/// polled.
///
/// P1 draws a card once. A marker is a reference to a file the bot wrote; the file may already be
/// gone (the snapshot route answers that), the host may refuse it, and the reply must still read as
/// a reply. So the loader's job is narrow:
///
/// * **One request per card.** A body pass happens every frame while a turn streams, and a
///   `LazyVStack` re-creates rows as they scroll — neither may become a second round trip.
/// * **A remembered failure.** `unavailable` is cached like a success. Retrying on every body pass
///   is how a bubble ends up flickering between a card and its apology.
/// * **No clock.** Polling (`final`, `mtime`) is P3; nothing here starts a timer.
/// * **The message's own row.** The key carries the message id as well as the session, because the
///   host snapshots a card per `(session, message, card)`: two messages naming one file are two
///   cards, and sharing a cache entry would show one message's card in the other's bubble.
///
/// It is `@MainActor` because everything it holds is view state: a row reads it, and a row is main
/// thread by definition. The network call itself suspends, so nothing blocks.
@MainActor
public final class CardLoader {

    /// What a marker's card is doing right now.
    ///
    /// `unavailable` keeps the *reason* rather than one flattened string: the reader sees the same
    /// line either way (`Card not available`), but "the file is gone" and "the id could never be
    /// fetched" are different facts to log, and a test can tell them apart.
    public enum State: Equatable, Sendable {
        case idle
        case loading
        case loaded(CardModel)
        case unavailable(CardFetchError)

        public var card: Card? {
            if case .loaded(let model) = self { return model.card }
            return nil
        }

        /// Whether the row should draw a card, an apology, or nothing at all. Only a finished read
        /// draws: a half-second flash of "Card not available" over a card that is on its way is
        /// worse than the prose alone for that half second.
        public var isSettled: Bool {
            switch self {
            case .loaded, .unavailable: return true
            case .idle, .loading: return false
            }
        }
    }

    /// One card read: `(card id, session id, message id)`. The caller owns the transport — this
    /// type never knows whether the answer came from a bridge, a preview or a test.
    public typealias Fetch = (_ id: String, _ session: String, _ message: String) async throws -> CardFetch

    private struct Key: Hashable {
        let session: String
        let message: String
        let cardID: String
    }

    /// The cache every row shares. Two replies naming the same card are one request, and a row
    /// scrolled out and back in is not a second one.
    public static let shared = CardLoader()

    private var states: [Key: State] = [:]
    /// A call already on its way, so two rows showing one card await it instead of starting another.
    private var inFlight: [Key: Task<State, Never>] = [:]
    /// A soft ceiling. A long-lived app reads every card of every conversation it ever opened, and
    /// each entry is one small document; dropping the cache costs a re-read of what is on screen —
    /// never a wrong answer, because a row keeps its own copy in view state and only asks again for
    /// a card it does not hold.
    private static let cacheLimit = 256

    public init() {}

    /// What is already known, without touching the network.
    public func state(cardID: String, session: String, message: String) -> State {
        states[Key(session: session, message: message, cardID: cardID)] ?? .idle
    }

    /// The card a marker names, fetched at most once per `(session, message, card id)`.
    ///
    /// Never throws: every failure is a `State`, because a card is an extra under a reply and the
    /// reply has already been delivered by the time this runs.
    @discardableResult
    public func load(_ ref: CardRef,
                     session: String,
                     message: String,
                     using fetch: @escaping Fetch) async -> State {
        let key = Key(session: session, message: message, cardID: ref.id)
        // Settled already — including a failure. One read, one answer.
        if let known = states[key], known.isSettled { return known }
        // A call already on its way is the answer for every row showing this card.
        if let running = inFlight[key] { return await running.value }

        if states.count >= Self.cacheLimit { states.removeAll() }
        states[key] = .loading
        let task = Task { () -> State in
            do {
                let answer = try await fetch(ref.id, session, message)
                // `CardModel.decode` never throws: a document this client cannot draw is
                // `.unavailable`, which the row shows as the same one-line apology.
                return .loaded(CardModel.decode(answer.card))
            } catch let error as CardFetchError {
                return .unavailable(error)
            } catch {
                return .unavailable(.unreachable(error.localizedDescription))
            }
        }
        inFlight[key] = task
        let state = await task.value
        inFlight[key] = nil
        states[key] = state
        return state
    }

    /// The owner tapped an action: tick it and lock the rest *before* the host answers.
    ///
    /// This changes only what the card draws. The message itself goes out through the transcript's
    /// ordinary send path, so a tap invents no second network call and no second delivery.
    @discardableResult
    public func choose(_ action: Card.Action,
                       cardID: String,
                       session: String,
                       message: String) -> State {
        let key = Key(session: session, message: message, cardID: cardID)
        guard let known = states[key],
              case .loaded(.available(let card)) = known,
              !card.isResolved else {
            return states[key] ?? .idle
        }
        // `Card` is immutable on purpose — the chosen action is a copy, so the cached document
        // stays exactly what the host sent and the tick is clearly this device's own optimism.
        let ticked = Card(schema: card.schema,
                          kind: card.kind,
                          title: card.title,
                          status: card.status,
                          body: card.body,
                          actions: card.actions,
                          resolved: Card.Resolved(action: action.send),
                          email: card.email)
        let state = State.loaded(.available(ticked))
        states[key] = state
        return state
    }

    /// Forget every read. For a test, and for anything that has to re-read on purpose; P1 has no
    /// clock that would need it.
    public func reset() {
        states.removeAll()
        inFlight.removeAll()
    }
}
