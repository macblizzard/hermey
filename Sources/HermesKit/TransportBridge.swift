import Foundation

/// Everything `GatewayClient` needs from one connection: the event stream plus three verbs.
///
/// Deliberately a struct of closures rather than a protocol over an actor. The protocol core must be
/// drivable from recorded frames in tests (no socket, no URLSession, no main-actor hops), and a
/// closure bundle has no actor-isolation rules to get subtly wrong — an `actor` requirement whose
/// `events` property is `nonisolated` is exactly the kind of conformance that compiles differently
/// across toolchains.
public struct TransportBridge: @unchecked Sendable {
    /// Every state change, frame and malformed line, in wire order.
    public let events: AsyncStream<GatewayTransport.Event>

    private let connectImpl: @Sendable () async throws -> Void
    private let sendImpl: @Sendable (String) async throws -> Void
    private let disconnectImpl: @Sendable (String) async -> Void

    /// `@unchecked Sendable`: the closures are `@Sendable` and `AsyncStream` synchronises its own
    /// storage, but the compiler cannot see through that storage type to prove it.
    public init(events: AsyncStream<GatewayTransport.Event>,
                connect: @escaping @Sendable () async throws -> Void,
                send: @escaping @Sendable (String) async throws -> Void,
                disconnect: @escaping @Sendable (String) async -> Void) {
        self.events = events
        self.connectImpl = connect
        self.sendImpl = send
        self.disconnectImpl = disconnect
    }

    public func connect() async throws { try await connectImpl() }
    public func send(text: String) async throws { try await sendImpl(text) }
    public func disconnect(reason: String) async { await disconnectImpl(reason) }
}

extension GatewayTransport {
    /// A `TransportBridge` over this socket.
    ///
    /// The bridge captures *this* transport's stream, so one bridge is one connection: a client that
    /// reconnects builds a fresh `GatewayTransport` (a fresh URLSessionWebSocketTask) and gets a
    /// fresh stream with it. Reusing a finished stream would silently deliver nothing.
    public nonisolated func bridge() -> TransportBridge {
        TransportBridge(
            events: events,
            connect: { [self] in try await connect() },
            send: { [self] text in try await send(text: text) },
            disconnect: { [self] reason in await disconnect(reason: reason) })
    }
}
